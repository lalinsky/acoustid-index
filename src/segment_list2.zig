const std = @import("std");
const Allocator = std.mem.Allocator;

const SearchResults = @import("common.zig").SearchResults;

const SegmentId = @import("common.zig").SegmentId;

const Deadline = @import("utils/Deadline.zig");

const SharedPtr = @import("utils/smartptr.zig").SharedPtr;
const TieredMergePolicy = @import("segment_merge_policy.zig").TieredMergePolicy;

pub fn SegmentList(Segment: type) type {
    return struct {
        pub const Self = @This();

        pub const Node = SharedPtr(Segment);
        pub const List = std.ArrayListUnmanaged(Node);

        nodes: List,

        pub fn initEmpty() Self {
            const nodes = List.initBuffer(&.{});
            return .{
                .nodes = nodes,
            };
        }

        pub fn init(allocator: Allocator, num: usize) Allocator.Error!Self {
            const nodes = try List.initCapacity(allocator, num);
            errdefer nodes.deinit(allocator);

            return .{
                .nodes = nodes,
            };
        }

        pub fn createSharedEmpty(allocator: Allocator) Allocator.Error!SharedPtr(Self) {
            return try SharedPtr(Self).create(allocator, Self.initEmpty());
        }

        pub fn createShared(allocator: Allocator, capacity: anytype) Allocator.Error!SharedPtr(Self) {
            const self = try List.initCapacity(allocator, capacity);
            errdefer self.deinit(allocator);

            return try SharedPtr(Self).create(allocator, self);
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            for (self.nodes.items) |*node| {
                destroySegment(allocator, node);
            }
            self.nodes.deinit(allocator);
        }

        pub fn createSegment(allocator: Allocator, extra_init_args: anytype) Allocator.Error!Node {
            return Node.create(allocator, @call(.auto, Segment.init, .{allocator} ++ extra_init_args));
        }

        pub fn destroySegment(allocator: Allocator, node: *Node) void {
            node.release(allocator, .{});
        }

        pub fn appendSegmentInto(self: Self, copy: *Self, node: Node) void {
            for (self.nodes.items) |n| {
                copy.nodes.appendAssumeCapacity(n.acquire());
            }
            copy.nodes.appendAssumeCapacity(node.acquire());
        }

        pub fn appendSegment(self: *Self, allocator: Allocator, node: Node) Allocator.Error!Self {
            var copy = try Self.initCapacity(allocator, self.nodes.items.len + 1);
            self.appendSegmentInto(&copy, node);
            return copy;
        }

        pub fn removeSegment(self: *Self, allocator: Allocator, idx: usize) Allocator.Error!Self {
            var copy = try Self.initCapacity(allocator, self.nodes.items.len - 1);
            for (self.nodes.items, 0..) |n, i| {
                if (i != idx) {
                    copy.nodes.appendAssumeCapacity(n.acquire());
                }
            }
            return copy;
        }

        pub fn replaceSegments(self: *Self, allocator: Allocator, node: Node, start_idx: usize, end_idx: usize) Allocator.Error!Self {
            var copy = try Self.initCapacity(allocator, self.nodes.items.len + 1 - (end_idx - start_idx));
            for (self.nodes.items, 0..) |n, i| {
                if (i < start_idx or i >= end_idx) {
                    copy.nodes.appendAssumeCapacity(n.acquire());
                } else if (i == start_idx) {
                    copy.nodes.appendAssumeCapacity(node.acquire());
                }
            }
            return copy;
        }

        pub fn getIds(self: Self, allocator: Allocator) Allocator.Error!std.ArrayListUnmanaged(SegmentId) {
            var ids = try std.ArrayListUnmanaged(SegmentId).initCapacity(allocator, self.nodes.items.len);
            for (self.nodes.items) |node| {
                ids.appendAssumeCapacity(node.segment.id);
            }
            return ids;
        }

        pub fn search(self: Self, hashes: []const u32, results: *SearchResults, deadline: Deadline) !void {
            for (self.nodes.items) |node| {
                if (deadline.isExpired()) {
                    return error.Timeout;
                }
                try node.value.search(hashes, results);
            }
        }

        pub fn getMaxCommitId(self: Self) u64 {
            var max_commit_id: u64 = 0;
            for (self.nodes.items) |node| {
                max_commit_id = @max(max_commit_id, node.value.max_commit_id);
            }
            return max_commit_id;
        }

        fn compareByVersion(_: void, lhs: u32, rhs: Node) bool {
            return lhs < rhs.value.id.version;
        }

        pub fn hasNewerVersion(self: *const Self, doc_id: u32, version: u32) bool {
            var i = self.nodes.items.len;
            while (i > 0) {
                i -= 1;
                const node = self.nodes.items[i];
                if (node.value.id.version > version) {
                    if (node.value.docs.contains(doc_id)) {
                        return true;
                    }
                } else {
                    break;
                }
            }
            return false;
        }

        pub fn count(self: Self) usize {
            return self.nodes.items.len;
        }

        pub fn getFirst(self: Self) ?Node {
            return if (self.nodes.items.len > 0) self.nodes.items[0] else null;
        }

        pub fn getLast(self: Self) ?Node {
            return self.nodes.getLastOrNull();
        }
    };
}

fn getSegmentSize(comptime T: type) fn (SharedPtr(T)) usize {
    const tmp = struct {
        fn getSize(segment: SharedPtr(T)) usize {
            return segment.value.getSize();
        }
    };
    return tmp.getSize;
}

pub fn SegmentListManager(Segment: type) type {
    return struct {
        pub const Self = @This();
        pub const List = SegmentList(Segment);
        pub const MergePolicy = TieredMergePolicy(List.Node, getSegmentSize(Segment));

        segments: SharedPtr(List),
        merge_policy: MergePolicy,
        num_allowed_segments: std.atomic.Value(u32),

        pub fn init(allocator: Allocator, merge_policy: MergePolicy) !Self {
            const segments = try SharedPtr(List).create(allocator, List.initEmpty());
            return Self{
                .segments = segments,
                .merge_policy = merge_policy,
                .num_allowed_segments = std.atomic.Value(u32).init(0),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.segments.release(allocator, .{allocator});
        }

        pub fn count(self: Self) usize {
            return self.segments.value.nodes.items.len;
        }

        pub fn swap(self: *Self, allocator: Allocator, segments_list: List) !void {
            var segments = try SharedPtr(List).create(allocator, segments_list);
            defer segments.release(allocator, .{allocator});

            self.segments.swap(&segments);
        }
    };
}

test "SegmentList" {
    const MockSegment = struct {
        pub fn init(allocator: Allocator) @This() {
            _ = allocator;
            return .{};
        }

        pub fn deinit(self: *@This()) void {
            _ = self;
        }

        pub fn search(self: @This(), hashes: []const u32, results: *SearchResults) !void {
            _ = self;
            _ = hashes;
            _ = results;
        }
    };

    const MockSegmentList = SegmentList(MockSegment);

    const allocator = std.testing.allocator;

    var segments1 = MockSegmentList.initEmpty();
    defer segments1.deinit(allocator);

    var node = try MockSegmentList.createSegment(allocator, .{});
    defer MockSegmentList.destroySegment(allocator, &node);

    var segments2 = try segments1.appendSegment(allocator, node);
    defer segments2.deinit(allocator);

    var segments3 = try segments2.removeSegment(allocator, 0);
    defer segments3.deinit(allocator);

    var segments4 = try segments2.replaceSegments(allocator, node, 0, 1);
    defer segments4.deinit(allocator);

    var results = SearchResults.init(allocator);
    defer results.deinit();

    try segments1.search(&[_]u32{ 1, 2, 3 }, &results, .{});
    try segments2.search(&[_]u32{ 1, 2, 3 }, &results, .{});
    try segments3.search(&[_]u32{ 1, 2, 3 }, &results, .{});
    try segments4.search(&[_]u32{ 1, 2, 3 }, &results, .{});
}