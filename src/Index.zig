const std = @import("std");
const log = std.log.scoped(.index);

const zul = @import("zul");

const InMemoryIndex = @import("InMemoryIndex.zig");

const common = @import("common.zig");
const SearchResults = common.SearchResults;
const Change = common.Change;
const SegmentID = common.SegmentID;

const Deadline = @import("utils/Deadline.zig");

const Segment = @import("Segment.zig");
const SegmentList = Segment.List;

const Oplog = @import("Oplog.zig");

const filefmt = @import("filefmt.zig");

const Self = @This();

const Options = struct {
    min_segment_size: usize = 1000,
};

options: Options,

is_open: bool = false,

dir: std.fs.Dir,
allocator: std.mem.Allocator,
stage: InMemoryIndex,
segments: SegmentList,
write_lock: std.Thread.RwLock = .{},

scheduler: zul.Scheduler(Task, *Self),
last_cleanup_at: i64 = 0,
cleanup_interval: i64 = 1000,

max_segment_size: usize = 4 * 1024 * 1024 * 1024,

oplog: Oplog,
oplog_dir: std.fs.Dir,

const Task = union(enum) {
    cleanup: void,

    pub fn run(task: Task, index: *Self, at: i64) void {
        _ = at;
        switch (task) {
            .cleanup => {
                index.cleanup() catch |err| {
                    log.err("cleanup failed: {}", .{err});
                };
            },
        }
    }
};

pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, options: Options) !Self {
    var oplog_dir = try dir.makeOpenPath("oplog", .{ .iterate = true });
    errdefer oplog_dir.close();

    return .{
        .options = options,
        .dir = dir,
        .allocator = allocator,
        .stage = InMemoryIndex.init(allocator, .{ .max_segment_size = options.min_segment_size }),
        .segments = SegmentList.init(allocator),
        .scheduler = zul.Scheduler(Task, *Self).init(allocator),
        .oplog = Oplog.init(allocator, oplog_dir),
        .oplog_dir = oplog_dir,
    };
}

pub fn deinit(self: *Self) void {
    self.scheduler.deinit();
    self.oplog.deinit();
    self.oplog_dir.close();
    self.stage.deinit();
    self.segments.deinit();
}

pub const OpenOptions = struct {
    create: bool = false,
};

pub fn open(self: *Self, options: OpenOptions) !void {
    self.write_lock.lock();
    defer self.write_lock.unlock();

    if (self.is_open) return;

    try self.scheduler.start(self);

    self.readIndexFile() catch |err| {
        if (err == error.FileNotFound and options.create) {
            try self.writeIndexFile();
        } else {
            return err;
        }
    };

    try self.oplog.open(self.segments.getMaxCommitId(), &self.stage);

    self.is_open = true;
}

fn writeIndexFile(self: *Self) !void {
    var file = try self.dir.atomicFile(filefmt.index_file_name, .{});
    defer file.deinit();

    var ids = std.ArrayList(SegmentID).init(self.allocator);
    defer ids.deinit();

    try self.segments.getIds(&ids);

    try filefmt.writeIndexFile(file.file.writer(), ids);

    try file.finish();
}

fn readIndexFile(self: *Self) !void {
    var file = try self.dir.openFile(filefmt.index_file_name, .{});
    defer file.close();

    var ids = std.ArrayList(SegmentID).init(self.allocator);
    defer ids.deinit();

    try filefmt.readIndexFile(file.reader(), &ids);

    for (ids.items) |id| {
        const node = try self.segments.createSegment();
        try node.data.open(self.dir, id);
        self.segments.segments.append(node);
    }
}

fn prepareMerge(self: *Self) !?SegmentList.PreparedMerge {
    self.write_lock.lockShared();
    defer self.write_lock.unlockShared();

    const merge_opt = try self.segments.prepareMerge(.{ .max_segment_size = self.max_segment_size });
    if (merge_opt) |merge| {
        errdefer self.segments.destroySegment(merge.target);
        try merge.target.data.merge(self.dir, merge.sources, self.segments);
        return merge;
    }
    return null;
}

fn finnishMerge(self: *Self, merge: SegmentList.PreparedMerge) !void {
    self.write_lock.lock();
    defer self.write_lock.unlock();

    errdefer self.segments.destroySegment(merge.target);

    errdefer merge.target.data.delete(self.dir);

    self.segments.applyMerge(merge);
    errdefer self.segments.revertMerge(merge);

    try self.writeIndexFile();

    self.segments.destroyMergedSegments(merge);

    log.info("committed merge segment {}:{}", .{ merge.target.data.id.version, merge.target.data.id.included_merges });
}

fn compact(self: *Self) !void {
    while (true) {
        const merge_opt = try self.prepareMerge();
        if (merge_opt) |merge| {
            try self.finnishMerge(merge);
        } else {
            break;
        }
    }
}

fn cleanup(self: *Self) !void {
    log.info("running cleanup", .{});

    var max_commit_id: ?u64 = null;

    if (self.stage.maybeFreezeOldestSegment()) |source_segment| {
        const node = try self.segments.createSegment();
        errdefer self.segments.destroySegment(node);

        try node.data.convert(self.dir, source_segment);

        errdefer node.data.delete(self.dir);

        self.write_lock.lock();
        defer self.write_lock.unlock();

        self.segments.segments.append(node);
        errdefer self.segments.segments.remove(node);

        try self.writeIndexFile();

        self.stage.removeFrozenSegment(source_segment);
        max_commit_id = node.data.max_commit_id;
    }

    if (max_commit_id) |commit_id| {
        self.oplog.truncate(commit_id) catch |err| {
            log.err("failed to truncate oplog: {}", .{err});
        };
    }

    try self.compact();
}

pub fn update(self: *Self, changes: []const Change) !void {
    self.write_lock.lockShared();
    defer self.write_lock.unlockShared();

    if (!self.is_open) {
        return error.NotOpened;
    }

    try self.oplog.write(changes, &self.stage);
    try self.scheduler.scheduleIn(.{ .cleanup = {} }, 0);
}

pub fn search(self: *Self, hashes: []const u32, results: *SearchResults, deadline: Deadline) !void {
    self.write_lock.lockShared();
    defer self.write_lock.unlockShared();

    if (!self.is_open) {
        return error.NotOpened;
    }

    const sorted_hashes = try self.allocator.dupe(u32, hashes);
    defer self.allocator.free(sorted_hashes);
    std.sort.pdq(u32, sorted_hashes, {}, std.sort.asc(u32));

    try self.segments.search(sorted_hashes, results, deadline);
    try self.stage.search(sorted_hashes, results, deadline);

    results.sort();
}

test "insert and search" {
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    var index = try Self.init(std.testing.allocator, tmpDir.dir, .{});
    defer index.deinit();

    try index.open(.{ .create = true });

    try index.update(&[_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 1, 2, 3 },
    } }});

    var results = SearchResults.init(std.testing.allocator);
    defer results.deinit();

    try index.search(&[_]u32{ 1, 2, 3 }, &results, .{});

    try std.testing.expectEqual(1, results.count());

    const result = results.get(1);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(1, result.?.id);
    try std.testing.expectEqual(3, result.?.score);
    try std.testing.expect(result.?.version != 0);
}

test "persistance" {
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    {
        var index = try Self.init(std.testing.allocator, tmpDir.dir, .{ .min_segment_size = 1000 });
        defer index.deinit();

        try index.open(.{ .create = true });

        var hashes_buf: [100]u32 = undefined;
        const hashes = hashes_buf[0..];
        var prng = std.rand.DefaultPrng.init(0);
        const rand = prng.random();
        for (0..100) |i| {
            for (hashes) |*h| {
                h.* = std.rand.int(rand, u32);
            }
            try index.update(&[_]Change{.{ .insert = .{
                .id = @intCast(i),
                .hashes = hashes,
            } }});
        }
    }

    {
        var index = try Self.init(std.testing.allocator, tmpDir.dir, .{});
        defer index.deinit();

        try index.open(.{ .create = false });
    }
}
