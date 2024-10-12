const std = @import("std");
const log = std.log;
const io = std.io;

const Item = @import("common.zig").Item;

const filefmt = @import("filefmt.zig");

const Self = @This();

const default_block_size = 1024;

allocator: std.mem.Allocator,
version: u32,
docs: std.AutoHashMap(u32, bool),
items: std.ArrayList(Item),
frozen: bool = false,
merged: u32 = 0,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .docs = std.AutoHashMap(u32, bool).init(allocator),
        .items = std.ArrayList(Item).init(allocator),
        .version = 0,
    };
}

pub fn deinit(self: *Self) void {
    self.docs.deinit();
    self.items.deinit();
}

pub fn write(self: *Self, writer: anytype, block_size: comptime_int) !void {
    if (self.version == 0) {
        return error.InvalidSegmentVersion;
    }

    var block_data: [block_size]u8 = undefined;
    var items = self.items.items[0..];
    while (items.len > 0) {
        const n = try filefmt.writeBlock(block_data[0..], items);
        items = items[n..];
        try writer.writeAll(block_data[0..]);
    }
}

pub fn ensureSorted(self: *Self) void {
    std.sort.pdq(Item, self.items.items, {}, Item.cmp);
}

const testing = std.testing;

test "write to file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    var file = try tmp.dir.createFile("test.dat", .{});
    defer file.close();

    var segment = Self.init(testing.allocator);
    defer segment.deinit();

    segment.version = 1;
    try segment.docs.put(1, true);
    try segment.items.append(Item{ .hash = 1, .docId = 1 });
    try segment.items.append(Item{ .hash = 2, .docId = 1 });

    segment.ensureSorted();

    try segment.write(file, default_block_size);
}
