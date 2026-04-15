const std = @import("std");
const builtin = @import("builtin");

var log_buffer: [4096]u8 = @splat(0);
var file_log: std.Io.File = undefined;
var file_writer: std.Io.File.Writer = undefined;
var writer: *std.Io.Writer = undefined;

/// PSP has no per-user data dir concept; the log sits at CWD (which is
/// where the EBOOT lives) regardless of what `data_dir` points at. Every
/// other platform routes through the engine-resolved data dir so
/// Finder-launched `.app` bundles don't try to write into read-only
/// bundle internals.
pub fn init(io: std.Io, data_dir: std.Io.Dir) !void {
    if (builtin.os.tag == .psp) {
        file_log = try std.Io.Dir.cwd().createFile(io, "ms0:/aether.log", .{ .truncate = true });
    } else {
        file_log = try data_dir.createFile(io, "aether.log", .{ .truncate = true });
    }
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
