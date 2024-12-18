const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("jemalloc/jemalloc.h");
});

pub const allocator = Allocator{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .free = free,
    },
};

fn alloc(_: *anyopaque, n: usize, log2_align: u8, return_address: usize) ?[*]u8 {
    _ = return_address;

    const alignment = @as(usize, 1) << @as(Allocator.Log2Align, @intCast(log2_align));
    const ptr = c.je_aligned_alloc(alignment, n) orelse return null;
    return @ptrCast(ptr);
}

fn resize(
    _: *anyopaque,
    buf: []u8,
    log2_buf_align: u8,
    new_len: usize,
    return_address: usize,
) bool {
    _ = log2_buf_align;
    _ = return_address;

    if (new_len <= buf.len)
        return true;

    return new_len <= c.je_malloc_usable_size(buf.ptr);
}

fn free(_: *anyopaque, buf: []u8, log2_buf_align: u8, return_address: usize) void {
    _ = log2_buf_align;
    _ = return_address;
    c.je_free(buf.ptr);
}

test "basic" {
    const buf = try allocator.alloc(u8, 256);
    defer allocator.free(buf);
}
