const std = @import("std");
const fs = std.fs;
const log = std.log.scoped(.index);

const zul = @import("zul");

const InMemoryIndex = @import("InMemoryIndex.zig");

const common = @import("common.zig");
const SearchResults = common.SearchResults;
const Change = common.Change;

const Deadline = @import("utils/Deadline.zig");

const Segment = @import("Segment.zig");
const Segments = std.DoublyLinkedList(Segment);

const Oplog = @import("Oplog.zig");

const filefmt = @import("filefmt.zig");

const Self = @This();

dir: fs.Dir,
allocator: std.mem.Allocator,
stage: InMemoryIndex,
segments: Segments,
write_lock: std.Thread.RwLock = .{},

scheduler: zul.Scheduler(Task, *Self),
last_cleanup_at: i64 = 0,
cleanup_interval: i64 = 1000,
run_cleanup: bool = true,

oplog: Oplog,

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

pub fn init(allocator: std.mem.Allocator, dir: fs.Dir) Self {
    var self = Self{
        .dir = dir,
        .allocator = allocator,
        .stage = InMemoryIndex.init(allocator),
        .segments = .{},
        .scheduler = zul.Scheduler(Task, *Self).init(allocator),
        .oplog = Oplog.init(allocator, dir),
    };
    self.stage.auto_cleanup = true;
    return self;
}

pub fn start(self: *Self) !void {
    try self.scheduler.start(self);
}

pub fn deinit(self: *Self) void {
    self.oplog.deinit();
    self.stage.deinit();
    while (self.segments.popFirst()) |node| {
        self.destroySegment(node);
    }
    self.scheduler.deinit();
}

fn createSegment(self: *Self) !*Segments.Node {
    const node = try self.allocator.create(Segments.Node);
    node.data = Segment.init(self.allocator);
    return node;
}

fn destroySegment(self: *Self, node: *Segments.Node) void {
    node.data.deinit();
    self.allocator.destroy(node);
}

const index_file_name = "index.dat";

fn write(self: *Self) !void {
    var file = try self.dir.atomicFile(index_file_name, .{});
    defer file.deinit();

    var segments = std.ArrayList(Segment.Version).init(self.allocator);
    defer segments.deinit();

    try segments.ensureTotalCapacity(self.segments.len);

    var it = self.segments.first;
    while (it) |node| : (it = node.next) {
        try segments.append(node.data.version);
    }

    try filefmt.writeIndexFile(file.file.writer(), segments);

    try file.finish();
}

fn read(self: *Self) !void {
    var file = try self.dir.openFile(index_file_name, .{});
    defer file.close();

    var segments = std.ArrayList(Segment.Version).init(self.allocator);
    defer segments.deinit();

    try filefmt.readIndexFile(file.reader(), segments);
    return error.TODO;
}

fn cleanup(self: *Self) !void {
    if (!self.run_cleanup) return;

    log.info("running cleanup", .{});

    // try self.stage.cleanup();

    if (self.stage.freezeFirstSegment()) |segment| {
        var commited = false;
        const node = try self.createSegment();
        defer {
            if (!commited) self.destroySegment(node);
        }

        try node.data.convert(self.dir, segment);

        self.write_lock.lock();
        defer self.write_lock.unlock();

        try self.write();

        self.stage.removeSegment(segment);
        self.segments.append(node);
        self.oplog.truncate(node.data.max_commit_id);
        commited = true;
    }
}

pub fn update(self: *Self, changes: []const Change) !void {
    const commit_id = try self.oplog.write(changes);
    try self.stage.update(changes, commit_id);
    try self.scheduler.scheduleIn(.{ .cleanup = {} }, 0);
}

pub fn search(self: *Self, hashes: []const u32, results: *SearchResults, deadline: Deadline) !void {
    self.write_lock.lockShared();
    defer self.write_lock.unlockShared();

    const sorted_hashes = try self.allocator.dupe(u32, hashes);
    defer self.allocator.free(sorted_hashes);
    std.sort.pdq(u32, sorted_hashes, {}, std.sort.asc(u32));

    var it = self.segments.first;
    while (it) |node| : (it = node.next) {
        if (deadline.isExpired()) {
            return error.Timeout;
        }
        try node.data.search(sorted_hashes, results);
    }

    try self.stage.search(sorted_hashes, results, deadline);

    results.sort();
}

test "insert and search" {
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    var index = Self.init(std.testing.allocator, tmpDir.dir);
    defer index.deinit();

    try index.start();

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
