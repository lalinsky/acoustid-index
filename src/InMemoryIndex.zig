const std = @import("std");
const log = std.log;

const Deadline = @import("utils/Deadline.zig");

const assert = std.debug.assert;

const common = @import("common.zig");
const Item = common.Item;
const SearchResults = common.SearchResults;
const Change = common.Change;

const segment_list = @import("segment_list.zig");
const InMemorySegment = @import("InMemorySegment.zig");
const InMemorySegmentList = segment_list.SegmentList(InMemorySegment);

const Options = struct {
    max_segment_size: usize = 1_000_000,
};

options: Options,
allocator: std.mem.Allocator,
write_lock: std.Thread.RwLock,
merge_lock: std.Thread.Mutex,
segments: InMemorySegmentList,
auto_cleanup: bool = true,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, options: Options) Self {
    return .{
        .options = options,
        .allocator = allocator,
        .write_lock = .{},
        .merge_lock = .{},
        .segments = InMemorySegmentList.init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.write_lock.lock();
    defer self.write_lock.unlock();

    self.segments.deinit();
}

pub const PendingUpdate = struct {
    node: *InMemorySegmentList.List.Node,
};

pub fn update(self: *Self, changes: []const Change, commit_id: u64) !void {
    const txn = try self.prepareUpdate(changes);
    self.commitUpdate(txn, commit_id);

    if (self.auto_cleanup) {
        self.mergeSegments() catch |err| {
            std.debug.print("mergeSegments failed: {}\n", .{err});
        };
    }
}

pub fn cancelUpdate(self: *Self, txn: PendingUpdate) void {
    self.segments.destroySegment(txn.node);
    self.write_lock.unlock();
}

pub fn commitUpdate(self: *Self, txn: PendingUpdate, commit_id: u64) void {
    self.segments.segments.append(txn.node);

    txn.node.data.max_commit_id = commit_id;
    if (txn.node.prev) |prev| {
        txn.node.data.id = prev.data.id.next();
    } else {
        txn.node.data.id = common.SegmentID.first();
    }

    self.write_lock.unlock();
}

pub fn prepareUpdate(self: *Self, changes: []const Change) !PendingUpdate {
    var saved = false;

    const node = try self.segments.createSegment();
    defer {
        if (!saved) self.segments.destroySegment(node);
    }

    var num_items: usize = 0;
    for (changes) |change| {
        switch (change) {
            .insert => |op| {
                num_items += op.hashes.len;
            },
            .delete => {},
        }
    }
    try node.data.items.ensureTotalCapacity(num_items);

    var i = changes.len;
    while (i > 0) {
        i -= 1;
        const change = changes[i];
        switch (change) {
            .insert => |op| {
                const result = try node.data.docs.getOrPut(op.id);
                if (!result.found_existing) {
                    result.value_ptr.* = true;
                    var items = try node.data.items.addManyAsSlice(op.hashes.len);
                    for (op.hashes, 0..) |hash, j| {
                        items[j] = .{ .hash = hash, .id = op.id };
                    }
                }
            },
            .delete => |op| {
                const result = try node.data.docs.getOrPut(op.id);
                if (!result.found_existing) {
                    result.value_ptr.* = false;
                }
            },
        }
    }

    node.data.ensureSorted();

    self.write_lock.lock();
    saved = true;
    return PendingUpdate{ .node = node };
}

pub fn cleanup(self: *Self) !void {
    try self.mergeSegments();
}

fn getMaxSegments(self: *Self, total_size: usize) usize {
    const max_level_size = @min(self.options.max_segment_size, @max(total_size / 2, 10));
    const min_level_size = @max(max_level_size / 1000, 10);
    const x = max_level_size / min_level_size;
    if (x == 0) {
        return 1;
    } else {
        return @max(1, std.math.log2_int(usize, x));
    }
}

const Merge = struct {
    first: *InMemorySegmentList.List.Node,
    last: *InMemorySegmentList.List.Node,
    replacement: *InMemorySegmentList.List.Node,
};

fn prepareMerge(self: *Self) !?Merge {
    self.write_lock.lockShared();
    defer self.write_lock.unlockShared();

    var total_size: usize = 0;
    var max_size: usize = 0;
    var min_size: usize = std.math.maxInt(usize);
    var num_segments: usize = 0;
    var segments_iter = self.segments.segments.first;
    while (segments_iter) |node| : (segments_iter = node.next) {
        if (node.data.frozen or node.data.items.items.len > self.options.max_segment_size) {
            continue;
        }
        num_segments += 1;
        total_size += node.data.items.items.len;
        max_size = @max(max_size, node.data.items.items.len);
        min_size = @min(min_size, node.data.items.items.len);
    }

    if (total_size == 0) {
        return null;
    }

    const max_segments = self.getMaxSegments(total_size);
    if (num_segments < max_segments) {
        return null;
    }

    var best_node: ?*InMemorySegmentList.List.Node = null;
    var best_score: f64 = std.math.inf(f64);
    segments_iter = self.segments.segments.first;
    var level_size = @as(f64, @floatFromInt(total_size)) / 2;
    while (segments_iter) |node| : (segments_iter = node.next) {
        if (node.data.frozen or node.data.items.items.len > self.options.max_segment_size) {
            continue;
        }
        if (node.next) |nextNode| {
            const merge_size = node.data.items.items.len + nextNode.data.items.items.len;
            const score = @as(f64, @floatFromInt(merge_size)) - level_size;
            if (score < best_score) {
                best_node = node;
                best_score = score;
            }
        }
        level_size /= 2;
    }

    if (best_node == null or best_node.?.next == null) {
        return null;
    }

    const node1 = best_node.?;
    const node2 = best_node.?.next.?;

    const segment1 = node1.data;
    const segment2 = node2.data;
    const segments = [2]InMemorySegment{ segment1, segment2 };

    var committed = false;

    const node = try self.segments.createSegment();
    defer {
        if (!committed) self.segments.destroySegment(node);
    }

    const merge = Merge{ .first = node1, .last = node2, .replacement = node };

    node.data.id = common.SegmentID.merge(segment1.id, segment2.id);
    node.data.max_commit_id = @max(segment1.max_commit_id, segment2.max_commit_id);

    var total_docs: usize = 0;
    var total_items: usize = 0;
    for (segments) |segment| {
        total_docs += segment.docs.count();
        total_items += segment.items.items.len;
    }

    try node.data.docs.ensureUnusedCapacity(@truncate(total_docs));
    try node.data.items.ensureTotalCapacity(total_items);

    {
        var skip_docs = std.AutoHashMap(u32, void).init(self.allocator);
        defer skip_docs.deinit();

        try skip_docs.ensureTotalCapacity(@truncate(total_docs / 10));

        for (segments) |segment| {
            skip_docs.clearRetainingCapacity();

            var docs_iter = segment.docs.iterator();
            while (docs_iter.next()) |entry| {
                const id = entry.key_ptr.*;
                const status = entry.value_ptr.*;
                if (!self.segments.hasNewerVersion(id, segment.id.version)) {
                    try node.data.docs.put(id, status);
                } else {
                    try skip_docs.put(id, {});
                }
            }

            for (segment.items.items) |item| {
                if (!skip_docs.contains(item.id)) {
                    try node.data.items.append(item);
                }
            }
        }
    }

    node.data.ensureSorted();

    committed = true;
    return merge;
}

fn checkSegments(self: *Self) void {
    var iter = self.segments.segments.first;
    while (iter) |node| : (iter = node.next) {
        if (!node.data.frozen) {
            if (node.prev) |prev| {
                node.data.id = prev.data.id.next();
            } else {
                node.data.id.included_merges = 0;
            }
        }
    }
}

fn commitMerge(self: *Self, merge: Merge) void {
    self.write_lock.lock();
    defer self.write_lock.unlock();

    self.segments.segments.insertAfter(merge.last, merge.replacement);

    var iter: ?*InMemorySegmentList.List.Node = merge.first;
    while (iter) |node| {
        iter = node.next;
        self.segments.removeAndDestroy(node);
        if (node == merge.last) break;
    }

    self.checkSegments();
}

fn mergeSegments(self: *Self) !void {
    self.merge_lock.lock();
    defer self.merge_lock.unlock();

    const maybeMerge = try self.prepareMerge();
    if (maybeMerge) |merge| {
        self.commitMerge(merge);
    }
}

// Freezes the oldest segment, if the segment is already at its max size.
// This is called periodically by the cleanup process of the main index.
// Frozen segments are then persisted to disk and removed from the in-memory index.
pub fn maybeFreezeOldestSegment(self: *Self) ?*InMemorySegment {
    self.merge_lock.lock();
    defer self.merge_lock.unlock();

    self.write_lock.lockShared();
    defer self.write_lock.unlockShared();

    const first = self.segments.segments.first;
    if (first) |node| {
        if (node.next != null) { // only continue if there is more than one segment
            const segment = &node.data;
            if (segment.frozen) {
                return segment;
            }
            if (segment.items.items.len >= self.options.max_segment_size) {
                segment.frozen = true;
                return segment;
            }
        }
    }
    return null;
}

// Removes previously frozen segment that is no longer needed.
// This is called from the cleanup process of the main index, when the
// segment has already been persisted to disk.
pub fn removeFrozenSegment(self: *Self, segment: *InMemorySegment) void {
    self.merge_lock.lock();
    defer self.merge_lock.unlock();

    self.write_lock.lock();
    defer self.write_lock.unlock();

    var it = self.segments.segments.first;
    while (it) |node| : (it = node.next) {
        if (&node.data == segment) {
            if (node.data.frozen) {
                self.segments.removeAndDestroy(node);
                return;
            }
        }
    }
}

pub fn search(self: *Self, hashes: []const u32, results: *SearchResults, deadline: Deadline) !void {
    self.write_lock.lockShared();
    defer self.write_lock.unlockShared();

    try self.segments.search(hashes, results, deadline);
}

test "insert and search" {
    var index = Self.init(std.testing.allocator, .{});
    defer index.deinit();

    try index.update(&[_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 1, 2, 3 },
    } }}, 1);

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

test "insert, partial update and search" {
    var index = Self.init(std.testing.allocator, .{});
    defer index.deinit();

    try index.update(&[_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 1, 2, 3 },
    } }}, 1);

    try index.update(&[_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 1, 2, 4 },
    } }}, 2);

    var results = SearchResults.init(std.testing.allocator);
    defer results.deinit();

    try index.search(&[_]u32{ 1, 2, 3 }, &results, .{});

    try std.testing.expectEqual(1, results.count());

    const result = results.get(1);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(1, result.?.id);
    try std.testing.expectEqual(2, result.?.score);
    try std.testing.expect(result.?.version != 0);
}

test "insert, full update and search" {
    var index = Self.init(std.testing.allocator, .{});
    defer index.deinit();

    try index.update(&[_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 1, 2, 3 },
    } }}, 1);

    try index.update(&[_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 100, 200, 300 },
    } }}, 2);

    var results = SearchResults.init(std.testing.allocator);
    defer results.deinit();

    try index.search(&[_]u32{ 1, 2, 3 }, &results, .{});

    const result = results.get(1);
    try std.testing.expect(result == null or result.?.score == 0);
}

test "insert, full update (multiple times) and search" {
    var index = Self.init(std.testing.allocator, .{});
    defer index.deinit();

    var commit_id: u64 = 1;

    var i: u32 = 1000;
    while (i > 0) : (i -= 1) {
        try index.update(&[_]Change{.{ .insert = .{
            .id = i % 10,
            .hashes = &[_]u32{ i * 1000 + 1, i * 1000 + 2, i * 1000 + 3 },
        } }}, commit_id);
        commit_id += 1;
    }
    i += 1;

    var results = SearchResults.init(std.testing.allocator);
    defer results.deinit();

    try index.search(&[_]u32{ i * 1000 + 1, i * 1000 + 2, i * 1000 + 3 }, &results, .{});

    try std.testing.expectEqual(1, results.count());

    const result = results.get(i % 10);
    try std.testing.expect(result != null);
    try std.testing.expectEqual(1, result.?.id);
    try std.testing.expectEqual(3, result.?.score);
    try std.testing.expect(result.?.version != 0);
}

test "insert, delete and search" {
    var index = Self.init(std.testing.allocator, .{});
    defer index.deinit();

    try index.update(&[_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 1, 2, 3 },
    } }}, 1);

    try index.update(&[_]Change{.{ .delete = .{
        .id = 1,
    } }}, 2);

    var results = SearchResults.init(std.testing.allocator);
    defer results.deinit();

    try index.search(&[_]u32{ 1, 2, 3 }, &results, .{});

    const result = results.get(1);
    try std.testing.expect(result == null or result.?.score == 0);
}

test "freeze segment" {
    var index = Self.init(std.testing.allocator, .{ .max_segment_size = 100 });
    defer index.deinit();

    try index.update(&[_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 1, 2, 3 },
    } }}, 1);

    const segment1 = index.maybeFreezeOldestSegment();
    try std.testing.expect(segment1 == null);

    var commit_id: u64 = 2;
    for (1..100) |i| {
        try index.update(&[_]Change{.{ .insert = .{
            .id = @intCast(i),
            .hashes = &[_]u32{ 1, 2, 3 },
        } }}, commit_id);
        commit_id += 1;
    }

    const segment2 = index.maybeFreezeOldestSegment();
    try std.testing.expect(segment2 != null);
    try std.testing.expect(segment2.?.frozen);

    const segment3 = index.maybeFreezeOldestSegment();
    try std.testing.expect(segment3 == segment2);
}
