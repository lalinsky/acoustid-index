const std = @import("std");

const common = @import("common.zig");
const Change = common.Change;

const Self = @This();

pub const Entry = struct {
    id: u64 = 0,
    apply: ?common.Change = null,
    begin: ?struct {
        size: u32 = 0,
    } = null,
    commit: ?bool = null,
};

allocator: std.mem.Allocator,
dir: std.fs.Dir,

current_file: ?std.fs.File = null,
current_file_size: usize = 0,
max_file_size: usize = 1_000_000,

last_commit_id: u64 = 0,
smallest_needed_commit_id: u64 = 0,

pub fn init(allocator: std.mem.Allocator, dir: std.fs.Dir) Self {
    return Self{
        .allocator = allocator,
        .dir = dir,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

fn openFile(self: *Self, commit_id: u64) !std.fs.File {
    var buf: [32]u8 = undefined;
    const file_name = try std.fmt.bufPrint(&buf, "{d:0>20}.xlog", .{commit_id});

    const file = try self.dir.createFile(file_name, .{ .exclusive = true });
    return file;
}

fn getFile(self: *Self, commit_id: u64) !std.fs.File {
    if (self.current_file) |file| {
        if (self.current_file_size < self.max_file_size) {
            return file;
        }
        self.current_file = null;
        file.close();
    }

    const file = try self.openFile(commit_id);
    self.current_file = file;
    return file;
}

pub fn truncate(self: *Self, commit_id: u64) void {
    self.smallest_needed_commit_id = commit_id + 1;
}

const newline: u8 = '\n';

pub fn write(self: *Self, changes: []const Change) !u64 {
    const commit_id = self.last_commit_id + 1;

    const file = try self.getFile(commit_id);
    const writer = file.writer();

    const begin_entry = Entry{
        .id = commit_id,
        .begin = .{
            .size = @truncate(changes.len),
        },
    };
    try std.json.stringify(begin_entry, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte(newline);

    for (changes) |change| {
        const entry = Entry{
            .id = commit_id,
            .apply = change,
        };
        try std.json.stringify(entry, .{ .emit_null_optional_fields = false }, writer);
        try writer.writeByte(newline);
    }

    const commit_entry = Entry{
        .id = commit_id,
        .commit = true,
    };
    try std.json.stringify(commit_entry, .{ .emit_null_optional_fields = false }, writer);
    try writer.writeByte(newline);

    try file.sync();

    self.current_file_size += changes.len;
    self.last_commit_id = commit_id;
    return commit_id;
}

test "write entries" {
    var tmpDir = std.testing.tmpDir(.{});
    defer tmpDir.cleanup();

    var oplog = Self.init(std.testing.allocator, tmpDir.dir);
    defer oplog.deinit();

    const changes = [_]Change{.{ .insert = .{
        .id = 1,
        .hashes = &[_]u32{ 1, 2, 3 },
    } }};

    const commit_id = try oplog.write(&changes);
    try std.testing.expectEqual(1, commit_id);

    var file = try tmpDir.dir.openFile("00000000000000000001.xlog", .{});
    defer file.close();

    const contents = try file.reader().readAllAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(contents);

    const expected =
        \\{"id":1,"begin":{"size":1}}
        \\{"id":1,"apply":{"insert":{"id":1,"hashes":[1,2,3]}}}
        \\{"id":1,"commit":true}
        \\
    ;
    try std.testing.expectEqualStrings(expected, contents);
}
