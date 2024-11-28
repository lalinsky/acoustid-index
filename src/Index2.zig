const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.index);

const zul = @import("zul");

const Deadline = @import("utils/Deadline.zig");
const Change = @import("change.zig").Change;
const SearchResult = @import("common.zig").SearchResult;
const SearchResults = @import("common.zig").SearchResults;
const SegmentId = @import("common.zig").SegmentId;

const Oplog = @import("Oplog.zig");

const SegmentList = @import("segment_list2.zig").SegmentList;
const SegmentListManager = @import("segment_list2.zig").SegmentListManager;

const MemorySegment = @import("MemorySegment.zig");
const MemorySegmentList = SegmentList(MemorySegment);
const MemorySegmentNode = MemorySegmentList.Node;

const FileSegment = @import("FileSegment.zig");
const FileSegmentList = SegmentList(FileSegment);
const FileSegmentNode = FileSegmentList.Node;

const SharedPtr = @import("utils/smartptr.zig").SharedPtr;

const SegmentMerger = @import("segment_merger.zig").SegmentMerger;

const TieredMergePolicy = @import("segment_merge_policy.zig").TieredMergePolicy;

const filefmt = @import("filefmt.zig");

const Self = @This();

const Options = struct {
    create: bool = false,
    min_segment_size: usize = 250_000,
    max_segment_size: usize = 500_000_000,
};

options: Options,
allocator: std.mem.Allocator,

data_dir: std.fs.Dir,
oplog_dir: std.fs.Dir,

oplog: Oplog,

memory_segments: SegmentListManager(MemorySegment),
file_segments: SegmentListManager(FileSegment),

// These segments are owned by the index and can't be accessed without acquiring segments_lock.
// They can never be modified, only replaced.
segments_lock: std.Thread.RwLock = .{},

// These locks give partial access to the respective segments list.
//   1) For memory_segments, new segment can be appended to the list without this lock.
//   2) For file_segments, no write operation can happen without this lock.
// These lock can be only acquired before segments_lock, never after, to avoid deadlock situatons.
// They are mostly useful to allowing read access to segments during merge/checkpoint, without blocking real-time update.
file_segments_lock: std.Thread.Mutex = .{},
memory_segments_lock: std.Thread.Mutex = .{},

// Mutex used to control linearity of updates.
update_lock: std.Thread.Mutex = .{},

stopping: std.atomic.Value(bool),

checkpoint_event: std.Thread.ResetEvent = .{},
checkpoint_thread: ?std.Thread = null,

file_segment_merge_event: std.Thread.ResetEvent = .{},
file_segment_merge_thread: ?std.Thread = null,

memory_segment_merge_event: std.Thread.ResetEvent = .{},
memory_segment_merge_thread: ?std.Thread = null,

fn getFileSegmentSize(segment: SharedPtr(FileSegment)) usize {
    return segment.value.getSize();
}

fn getMemorySegmentSize(segment: SharedPtr(MemorySegment)) usize {
    return segment.value.getSize();
}

pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir, options: Options) !Self {
    var data_dir = try dir.makeOpenPath("data", .{ .iterate = true });
    errdefer data_dir.close();

    var oplog_dir = try dir.makeOpenPath("oplog", .{ .iterate = true });
    errdefer oplog_dir.close();

    const memory_segments = try SegmentListManager(MemorySegment).init(allocator, .{
        .min_segment_size = 100,
        .max_segment_size = options.min_segment_size,
        .segments_per_level = 5,
        .segments_per_merge = 10,
        .max_segments = 16,
    });

    const file_segments = try SegmentListManager(FileSegment).init(allocator, .{
        .min_segment_size = options.min_segment_size,
        .max_segment_size = options.max_segment_size,
        .segments_per_level = 10,
        .segments_per_merge = 10,
    });

    return .{
        .options = options,
        .allocator = allocator,
        .data_dir = data_dir,
        .oplog_dir = oplog_dir,
        .oplog = Oplog.init(allocator, oplog_dir),
        .segments_lock = .{},
        .memory_segments = memory_segments,
        .file_segments = file_segments,
        .stopping = std.atomic.Value(bool).init(false),
    };
}

pub fn deinit(self: *Self) void {
    self.stopping.store(true, .release);

    self.stopCheckpointThread();
    self.stopMemorySegmentMergeThread();
    self.stopFileSegmentMergeThread();

    self.memory_segments.deinit(self.allocator);
    self.file_segments.deinit(self.allocator);

    self.oplog.deinit();
    self.oplog_dir.close();
    self.data_dir.close();
}

fn flattenMemorySegmentIds(self: *Self) void {
    var iter = self.memory_segments.segments.first;
    var prev_node: @TypeOf(iter) = null;
    while (iter) |node| : (iter = node.next) {
        if (!node.data.frozen) {
            if (prev_node) |prev| {
                node.data.id = prev.data.id.next();
            } else {
                node.data.id.included_merges = 0;
            }
        }
        prev_node = node;
    }
}

fn maybeMergeMemorySegments(self: *Self) !bool {
    var snapshot = self.acquireSegments();
    defer self.releaseSegments(&snapshot);

    const memory_segments = snapshot.memory_segments.value;

    const num_allowed_segments = self.memory_segment_merge_policy.calculateBudget(memory_segments.nodes.items);
    self.num_allowed_memory_segments.store(num_allowed_segments, .monotonic);
    if (num_allowed_segments >= memory_segments.nodes.items.len) {
        return false;
    }

    const candidate = self.memory_segment_merge_policy.findSegmentsToMerge(memory_segments.nodes.items) orelse return false;

    var target = try MemorySegmentList.createSegment(self.allocator, .{});
    defer MemorySegmentList.destroySegment(self.allocator, &target);

    var merger = SegmentMerger(MemorySegment).init(self.allocator, memory_segments);
    defer merger.deinit();

    for (memory_segments.nodes.items[candidate.start..candidate.end]) |segment| {
        try merger.addSource(segment.value);
    }
    try merger.prepare();

    try target.value.merge(&merger);

    self.segments_lock.lock();
    defer self.segments_lock.unlock();

    try self.applyMerge(MemorySegment, &self.memory_segments, target);

    return target.value.getSize() >= self.options.min_segment_size;
}

fn applyMerge(self: Self, comptime T: type, old_segments: *SharedPtr(SegmentList(T)), merged: SharedPtr(T)) !void {
    var segments_list = try SegmentList(T).initCapacity(self.allocator, old_segments.value.nodes.items.len);
    errdefer segments_list.deinit(self.allocator);

    var inserted_merged = false;
    for (old_segments.value.nodes.items) |node| {
        if (merged.value.id.contains(node.value.id)) {
            if (!inserted_merged) {
                segments_list.nodes.appendAssumeCapacity(merged.acquire());
                inserted_merged = true;
            }
        } else {
            segments_list.nodes.appendAssumeCapacity(node.acquire());
        }
    }

    var segments = try SharedPtr(SegmentList(T)).create(self.allocator, segments_list);
    defer segments.release(self.allocator, .{self.allocator});

    old_segments.swap(&segments);
}

pub const PendingUpdate = struct {
    node: MemorySegmentNode,
    segments: SharedPtr(MemorySegmentList),
    finished: bool = false,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        if (self.finished) return;
        self.segments.release(allocator, .{allocator});
        MemorySegmentList.destroySegment(allocator, &self.node);
        self.finished = true;
    }
};

// Prepares update for later commit, will block until previous update has been committed.
fn prepareUpdate(self: *Self, changes: []const Change) !PendingUpdate {
    var node = try MemorySegmentList.createSegment(self.allocator, .{});
    errdefer MemorySegmentList.destroySegment(self.allocator, &node);

    try node.value.build(changes);

    self.update_lock.lock();
    errdefer self.update_lock.unlock();

    self.segments_lock.lockShared();
    defer self.segments_lock.unlockShared();

    const segments = try MemorySegmentList.createShared(self.allocator, self.memory_segments.count() + 1);

    return .{ .node = node, .segments = segments };
}

// Commits the update, does nothing if it has already been cancelled or committted.
fn commitUpdate(self: *Self, pending_update: *PendingUpdate, commit_id: u64) void {
    if (pending_update.finished) return;

    defer pending_update.deinit(self.allocator);

    self.segments_lock.lock();
    defer self.segments_lock.unlock();

    pending_update.node.value.max_commit_id = commit_id;
    pending_update.node.value.id = blk: {
        if (self.memory_segments.value.getLast()) |n| {
            break :blk n.value.id.next();
        } else if (self.file_segments.value.getFirst()) |n| {
            break :blk n.value.id.next();
        } else {
            break :blk SegmentId.first();
        }
    };

    self.memory_segments.segments.value.appendSegmentInto(pending_update.segments.value, pending_update.node);

    self.memory_segments.segments.swap(&pending_update.segments);

    pending_update.finished = true;
    self.update_lock.unlock();
}

// Cancels the update, does nothing if it has already been cancelled or committted.
fn cancelUpdate(self: *Self, pending_update: *PendingUpdate) void {
    if (pending_update.finished) return;

    defer pending_update.deinit(self.allocator);

    pending_update.finished = true;
    self.update_lock.unlock();
}

const Updater = struct {
    index: *Self,

    pub fn prepareUpdate(self: Updater, changes: []const Change) !PendingUpdate {
        return self.index.prepareUpdate(changes);
    }

    pub fn commitUpdate(self: Updater, pending_update: *PendingUpdate, commit_id: u64) void {
        self.index.commitUpdate(pending_update, commit_id);
    }

    pub fn cancelUpdate(self: Updater, pending_update: *PendingUpdate) void {
        self.index.cancelUpdate(pending_update);
    }
};

fn loadSegment(self: *Self, segment_id: SegmentId) !FileSegmentNode {
    var node = try FileSegmentList.createSegment(self.allocator, .{});
    errdefer FileSegmentList.destroySegment(self.allocator, &node);

    try node.value.open(self.data_dir, segment_id);

    return node;
}

fn loadSegments(self: *Self) !void {
    self.segments_lock.lock();
    defer self.segments_lock.unlock();

    const segment_ids = filefmt.readIndexFile(self.data_dir, self.allocator) catch |err| {
        if (err == error.FileNotFound) {
            if (self.options.create) {
                try filefmt.writeIndexFile(self.data_dir, &[_]SegmentId{});
                return;
            }
            return error.IndexNotFound;
        }
        return err;
    };
    defer self.allocator.free(segment_ids);

    var segments = try FileSegmentList.createShared(self.allocator, segment_ids.len);
    defer segments.release(self.allocator, .{self.allocator});

    for (segment_ids) |segment_id| {
        const node = try self.loadSegment(segment_id);
        segments.value.nodes.appendAssumeCapacity(node);
    }

    self.file_segments.segments.swap(&segments);
}

fn doCheckpoint(self: *Self) !bool {
    const start_time = std.time.milliTimestamp();

    var src = self.readyForCheckpoint() orelse return false;

    var src_reader = src.data.reader();
    defer src_reader.close();

    var dest = try self.file_segments.createSegment(.{self.allocator});
    errdefer self.file_segments.destroySegment(dest);

    try dest.data.build(self.data_dir, &src_reader);

    errdefer dest.data.delete(self.data_dir);

    self.file_segments_lock.lock();
    defer self.file_segments_lock.unlock();

    var ids = try self.file_segments.getIdsAfterAppend(dest, self.allocator);
    defer ids.deinit();

    try filefmt.writeIndexFile(self.data_dir, ids.items);

    // we are about to remove segment from the memory_segments list
    self.memory_segments_lock.lock();
    defer self.memory_segments_lock.unlock();

    self.segments_lock.lock();
    defer self.segments_lock.unlock();

    log.info("stage stats size={}, len={}", .{ self.memory_segments.getTotalSize(), self.memory_segments.segments.len });

    if (src != self.memory_segments.segments.first) {
        std.debug.panic("checkpoint node is not first in list", .{});
    }

    if (self.file_segments.segments.last) |last_file_segment| {
        if (last_file_segment.data.id.version >= dest.data.id.version) {
            std.debug.panic("inconsistent versions between memory and file segments", .{});
        }
    }

    self.file_segments.appendSegment(dest);
    self.memory_segments.removeAndDestroySegment(src);

    log.info("saved changes up to commit {} to disk", .{dest.data.max_commit_id});

    const end_time = std.time.milliTimestamp();
    log.info("checkpoint took {} ms", .{end_time - start_time});
    return true;
}

fn checkpointThreadFn(self: *Self) void {
    while (!self.stopping.load(.acquire)) {
        if (self.doCheckpoint()) |successful| {
            if (successful) {
                self.scheduleFileSegmentMerge();
                continue;
            }
            self.checkpoint_event.reset();
        } else |err| {
            log.err("checkpoint failed: {}", .{err});
        }
        self.checkpoint_event.timedWait(std.time.ns_per_min) catch continue;
    }
}

fn startCheckpointThread(self: *Self) !void {
    if (self.checkpoint_thread != null) return;

    log.info("starting checkpoint thread", .{});
    // self.checkpoint_thread = try std.Thread.spawn(.{}, checkpointThreadFn, .{self});
}

fn stopCheckpointThread(self: *Self) void {
    log.info("stopping checkpoint thread", .{});
    if (self.checkpoint_thread) |thread| {
        self.checkpoint_event.set();
        thread.join();
    }
    self.checkpoint_thread = null;
}

fn fileSegmentMergeThreadFn(self: *Self) void {
    while (!self.stopping.load(.acquire)) {
        if (self.maybeMergeFileSegments()) |successful| {
            if (successful) {
                continue;
            }
            self.file_segment_merge_event.reset();
        } else |err| {
            log.err("file segment merge failed: {}", .{err});
        }
        self.file_segment_merge_event.timedWait(std.time.ns_per_min) catch continue;
    }
}

fn startFileSegmentMergeThread(self: *Self) !void {
    if (self.file_segment_merge_thread != null) return;

    log.info("starting file segment merge thread", .{});
    //self.file_segment_merge_thread = try std.Thread.spawn(.{}, fileSegmentMergeThreadFn, .{self});
}

fn stopFileSegmentMergeThread(self: *Self) void {
    log.info("stopping file segment merge thread", .{});
    if (self.file_segment_merge_thread) |thread| {
        self.file_segment_merge_event.set();
        thread.join();
    }
    self.file_segment_merge_thread = null;
}

fn prepareFileSegmentMerge(self: *Self) !?FileSegmentList.PreparedMerge {
    self.segments_lock.lockShared();
    defer self.segments_lock.unlockShared();

    return try self.file_segments.prepareMerge();
}

fn maybeMergeFileSegments(self: *Self) !bool {
    var merge = try self.prepareFileSegmentMerge() orelse return false;
    defer merge.merger.deinit();
    errdefer self.file_segments.destroySegment(merge.target);

    // We are reading segment data without holding any lock here,
    // but it's OK, because are the only ones modifying segments.
    // The only other place with write access to the segment list is
    // the checkpoint thread, which is only ever adding new segments.
    try merge.target.data.build(self.data_dir, &merge.merger);
    errdefer merge.target.data.delete(self.data_dir);

    // By acquiring file_segments_lock, we make sure that the file_segments list
    // can't be modified by other threads.
    self.file_segments_lock.lock();
    defer self.file_segments_lock.unlock();

    var ids = try self.file_segments.getIdsAfterAppliedMerge(merge, self.allocator);
    defer ids.deinit();

    try filefmt.writeIndexFile(self.data_dir, ids.items);

    // We want to do this outside of segments_lock to avoid blocking searches more than necessary
    defer self.file_segments.cleanupAfterMerge(merge, .{self.data_dir});

    // This lock allows to modify the file_segments list, it's blocking all other threads.
    self.segments_lock.lock();
    defer self.segments_lock.unlock();

    self.file_segments.applyMerge(merge);

    log.info("committed merge segment {}:{}", .{ merge.target.data.id.version, merge.target.data.id.included_merges });
    return true;
}

fn memorySegmentMergeThreadFn(self: *Self) void {
    while (!self.stopping.load(.acquire)) {
        if (self.maybeMergeMemorySegments()) |successful| {
            if (successful) {
                self.checkpoint_event.set();
                continue;
            }
            self.memory_segment_merge_event.reset();
        } else |err| {
            log.err("memory segment merge failed: {}", .{err});
        }
        self.memory_segment_merge_event.timedWait(std.time.ns_per_min) catch continue;
    }
}

fn startMemorySegmentMergeThread(self: *Self) !void {
    if (self.memory_segment_merge_thread != null) return;

    log.info("starting memory segment merge thread", .{});
    self.memory_segment_merge_thread = try std.Thread.spawn(.{}, memorySegmentMergeThreadFn, .{self});
}

fn stopMemorySegmentMergeThread(self: *Self) void {
    log.info("stopping memory segment merge thread", .{});
    if (self.memory_segment_merge_thread) |thread| {
        self.memory_segment_merge_event.set();
        thread.join();
    }
    self.memory_segment_merge_thread = null;
}

pub fn open(self: *Self) !void {
    try self.loadSegments();
    try self.oplog.open(self.getMaxCommitId(), Updater{ .index = self });
    try self.startCheckpointThread();
    try self.startFileSegmentMergeThread();
    try self.startMemorySegmentMergeThread();
}

const Checkpoint = struct {
    src: *MemorySegmentNode,
    dest: ?*FileSegmentNode = null,
};

fn readyForCheckpoint(self: *Self) ?MemorySegmentNode {
    self.segments_lock.lockShared();
    defer self.segments_lock.unlockShared();

    if (self.segments.memory_segments.value.getFirstOrNull()) |first_node| {
        if (first_node.value.getSize() > self.options.min_segment_size) {
            return first_node.acquire();
        }
    }
    return null;
}

fn scheduleCheckpoint(self: *Self) void {
    self.checkpoint_event.set();
}

fn scheduleMemorySegmentMerge(self: *Self) void {
    self.segments_lock.lockShared();
    defer self.segments_lock.unlockShared();

    if (self.memory_segments.value.count() > self.num_allowed_memory_segments.load(.monotonic)) {
        self.memory_segment_merge_event.set();
    }
}

fn scheduleFileSegmentMerge(self: *Self) void {
    self.segments_lock.lockShared();
    defer self.segments_lock.unlockShared();

    if (self.file_segments.value.count() > self.num_allowed_file_segments.load(.monotonic)) {
        self.file_segment_merge_event.set();
    }
}

pub fn update(self: *Self, changes: []const Change) !void {
    log.debug("update with {} changes", .{changes.len});
    try self.oplog.write(changes, Updater{ .index = self });
    self.scheduleMemorySegmentMerge();
}

const SegmentsSnapshot = struct {
    file_segments: SharedPtr(FileSegmentList),
    memory_segments: SharedPtr(MemorySegmentList),
};

// Get the current segments lists and make sure they won't get deleted.
fn acquireSegments(self: *Self) SegmentsSnapshot {
    self.segments_lock.lockShared();
    defer self.segments_lock.unlockShared();

    return .{
        .file_segments = self.file_segments.segments.acquire(),
        .memory_segments = self.memory_segments.segments.acquire(),
    };
}

// Release the previously acquired segments lists, they will get deleted if no longer needed.
fn releaseSegments(self: *Self, segments: *SegmentsSnapshot) void {
    segments.file_segments.release(self.allocator, .{self.allocator});
    segments.memory_segments.release(self.allocator, .{self.allocator});
}

pub fn search(self: *Self, hashes: []const u32, allocator: std.mem.Allocator, deadline: Deadline) !SearchResults {
    const sorted_hashes = try allocator.dupe(u32, hashes);
    defer allocator.free(sorted_hashes);
    std.sort.pdq(u32, sorted_hashes, {}, std.sort.asc(u32));

    var results = SearchResults.init(allocator);
    errdefer results.deinit();

    var segments = self.acquireSegments();
    defer self.releaseSegments(&segments);

    try segments.file_segments.value.search(sorted_hashes, &results, deadline);
    try segments.memory_segments.value.search(sorted_hashes, &results, deadline);

    results.sort();
    return results;
}

pub fn getMaxCommitId(self: *Self) u64 {
    var segments = self.acquireSegments();
    defer self.releaseSegments(&segments);

    return @max(segments.file_segments.value.getMaxCommitId(), segments.memory_segments.value.getMaxCommitId());
}

test {
    _ = @import("index_tests.zig");
    _ = @import("segment_list2.zig");
}