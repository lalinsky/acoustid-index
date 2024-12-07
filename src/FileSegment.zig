const std = @import("std");
const log = std.log.scoped(.segment);
const assert = std.debug.assert;

const common = @import("common.zig");
const SearchResults = common.SearchResults;
const KeepOrDelete = common.KeepOrDelete;

const Item = @import("segment.zig").Item;
const SegmentInfo = @import("segment.zig").SegmentInfo;

const filefmt = @import("filefmt.zig");

const Self = @This();

pub const Options = struct {
    dir: std.fs.Dir,
};

allocator: std.mem.Allocator,
dir: std.fs.Dir,
info: SegmentInfo = .{},
attributes: std.StringHashMapUnmanaged(u64) = .{},
docs: std.AutoHashMapUnmanaged(u32, bool) = .{},
min_doc_id: u32 = 0,
max_doc_id: u32 = 0,
index: std.ArrayListUnmanaged(u32) = .{},
block_size: usize = 0,
blocks: []const u8,
merged: u32 = 0,
num_items: usize = 0,
delete_in_deinit: bool = false,

mmaped_file: ?std.fs.File = null,
mmaped_data: ?[]align(std.mem.page_size) u8 = null,

pub fn init(allocator: std.mem.Allocator, options: Options) Self {
    return Self{
        .allocator = allocator,
        .dir = options.dir,
        .blocks = undefined,
    };
}

pub fn deinit(self: *Self, delete_file: KeepOrDelete) void {
    var iter = self.attributes.iterator();
    while (iter.next()) |e| {
        self.allocator.free(e.key_ptr.*);
    }
    self.attributes.deinit(self.allocator);
    self.docs.deinit(self.allocator);
    self.index.deinit(self.allocator);

    if (self.mmaped_data) |data| {
        std.posix.munmap(data);
    }

    if (self.mmaped_file) |file| {
        file.close();
    }

    if (delete_file == .delete) {
        self.delete();
    }
}

pub fn getBlockData(self: Self, block: usize) []const u8 {
    return self.blocks[block * self.block_size .. (block + 1) * self.block_size];
}

pub fn search(self: Self, sorted_hashes: []const u32, results: *SearchResults) !void {
    var prev_block_no: usize = std.math.maxInt(usize);
    var prev_block_range_start: usize = 0;

    var block_items = std.ArrayList(Item).init(results.results.allocator);
    defer block_items.deinit();

    for (sorted_hashes) |hash| {
        var block_no = std.sort.lowerBound(u32, hash, self.index.items, {}, std.sort.asc(u32));
        if (block_no == self.index.items.len) {
            block_no = prev_block_range_start;
        }
        prev_block_range_start = block_no;

        while (block_no < self.index.items.len and self.index.items[block_no] <= hash) : (block_no += 1) {
            if (block_no != prev_block_no) {
                prev_block_no = block_no;
                const block_data = self.getBlockData(block_no);
                try filefmt.readBlock(block_data, &block_items);
            }
            const matches = std.sort.equalRange(Item, Item{ .hash = hash, .id = 0 }, block_items.items, {}, Item.cmpByHash);
            for (matches[0]..matches[1]) |i| {
                try results.incr(block_items.items[i].id, self.info.version);
            }
        }
    }
}

pub fn load(self: *Self, info: SegmentInfo) !void {
    try filefmt.readSegmentFile(self.dir, info, self);
}

pub fn delete(self: *Self) void {
    var file_name_buf: [filefmt.max_file_name_size]u8 = undefined;
    const file_name = filefmt.buildSegmentFileName(&file_name_buf, self.info);

    log.info("deleting segment file {s}", .{file_name});

    self.dir.deleteFile(file_name) catch |err| {
        if (err != error.FileNotFound) {
            log.err("failed to clean up segment file {s}: {}", .{ file_name, err });
        }
    };
}

pub fn cleanup(self: *Self) void {
    self.delete();
}

pub fn merge(self: *Self, source: anytype) !void {
    try self.build(source);
}

pub fn build(self: *Self, source: anytype) !void {
    var file_name_buf: [filefmt.max_file_name_size]u8 = undefined;
    const file_name = filefmt.buildSegmentFileName(&file_name_buf, source.segment.info);

    try filefmt.writeSegmentFile(self.dir, source);

    errdefer self.dir.deleteFile(file_name) catch |err| {
        if (err != error.FileNotFound) {
            log.err("failed to clean up segment file {s}: {}", .{ file_name, err });
        }
    };

    try filefmt.readSegmentFile(self.dir, source.segment.info, self);
}

test "build" {
    const MemorySegment = @import("MemorySegment.zig");

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var data_dir = try tmp_dir.dir.makeOpenPath("data", .{});
    defer data_dir.close();

    var source = MemorySegment.init(std.testing.allocator, .{});
    defer source.deinit(.delete);

    source.info = .{ .version = 1 };
    source.frozen = true;
    try source.docs.put(source.allocator, 1, true);
    try source.items.append(source.allocator, .{ .id = 1, .hash = 1 });
    try source.items.append(source.allocator, .{ .id = 1, .hash = 2 });

    var source_reader = source.reader();
    defer source_reader.close();

    var segment = Self.init(std.testing.allocator, .{ .dir = tmp_dir.dir });
    defer segment.deinit(.delete);

    try segment.build(&source_reader);

    try std.testing.expectEqualDeep(SegmentInfo{ .version = 1, .merges = 0 }, segment.info);
    try std.testing.expectEqual(1, segment.docs.count());
    try std.testing.expectEqual(1, segment.index.items.len);
}

pub fn getSize(self: Self) usize {
    return self.num_items;
}

pub fn reader(self: *const Self) Reader {
    return .{
        .segment = self,
        .items = std.ArrayList(Item).init(self.allocator),
    };
}

pub const Reader = struct {
    segment: *const Self,
    items: std.ArrayList(Item),
    index: usize = 0,
    block_no: usize = 0,

    pub fn close(self: *Reader) void {
        self.items.deinit();
    }

    pub fn read(self: *Reader) !?Item {
        while (self.index >= self.items.items.len) {
            if (self.block_no >= self.segment.index.items.len) {
                return null;
            }
            self.items.clearRetainingCapacity();
            self.index = 0;
            const block_data = self.segment.getBlockData(self.block_no);
            self.block_no += 1;
            try filefmt.readBlock(block_data, &self.items);
        }
        return self.items.items[self.index];
    }

    pub fn advance(self: *Reader) void {
        if (self.index < self.items.items.len) {
            self.index += 1;
        }
    }
};
