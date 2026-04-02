const std = @import("std");
const builtin = @import("builtin");

var log_buffer: [4096]u8 = @splat(0);
var file_log: std.Io.File = undefined;
var file_writer: std.Io.File.Writer = undefined;
var writer: *std.Io.Writer = undefined;

pub fn init(io: std.Io) !void {
    const log_path = if (builtin.os.tag == .psp) "ms0:/aether.log" else "aether.log";
    file_log = try std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true });
    file_writer = file_log.writer(io, &log_buffer);
    writer = &file_writer.interface;
}

pub fn deinit(io: std.Io) void {
    writer.flush() catch {};
    file_log.close(io);
}

pub fn aether_log_fn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = "(" ++ @tagName(scope) ++ ") ";

    const prefix = scope_prefix ++ "[" ++ comptime level.asText() ++ "]: ";

    writer.print(prefix ++ format ++ "\n", args) catch {};
    std.debug.print(prefix ++ format ++ "\n", args);
}
