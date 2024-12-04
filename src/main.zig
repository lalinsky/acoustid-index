const std = @import("std");
const zul = @import("zul");

const MultiIndex = @import("MultiIndex.zig");
const server = @import("server.zig");
const metrics = @import("metrics.zig");

pub const std_options = .{
    .log_level = .debug,
    .logFn = logHandler,
};

var current_log_level: std.log.Level = .info;

pub fn logHandler(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(level) <= @intFromEnum(current_log_level)) {
        const level_txt = comptime level.asText();
        const prefix2 = if (scope == .default) ": " else "(" ++ @tagName(scope) ++ "): ";
        const stderr = std.io.getStdErr().writer();
        var bw = std.io.bufferedWriter(stderr);
        const writer = bw.writer();

        std.debug.lockStdErr();
        defer std.debug.unlockStdErr();
        nosuspend {
            writer.print("{d:.3} " ++ level_txt ++ prefix2 ++ format ++ "\n", .{@as(f64, @floatFromInt(std.time.milliTimestamp())) / 1000.0} ++ args) catch return;
            bw.flush() catch return;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    var args = try zul.CommandLineArgs.parse(allocator);
    defer args.deinit();

    if (args.get("log-level")) |log_level_name| {
        if (std.meta.stringToEnum(std.log.Level, log_level_name)) |log_level| {
            current_log_level = log_level;
        } else {
            return error.InvalidLogLevel;
        }
    }

    const dir_path = args.get("dir") orelse ".";
    const dir = try std.fs.cwd().makeOpenPath(dir_path, .{ .iterate = true });

    const address = args.get("address") orelse "127.0.0.1";

    const port_str = args.get("port") orelse "8080";
    const port = try std.fmt.parseInt(u16, port_str, 10);

    _ = try std.net.Address.parseIp(address, port);

    const threads_str = args.get("threads") orelse "0";
    var threads = try std.fmt.parseInt(u16, threads_str, 10);
    if (threads == 0) {
        threads = @intCast(try std.Thread.getCpuCount());
    }

    try metrics.initializeMetrics(.{ .prefix = "aindex_" });

    var indexes = MultiIndex.init(allocator, dir);
    defer indexes.deinit();

    try server.run(allocator, &indexes, address, port, threads);
}

test {
    std.testing.refAllDecls(@This());
}
