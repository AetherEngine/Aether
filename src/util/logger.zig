const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

var log_buffer: [4096]u8 = @splat(0);
var file_log: std.Io.File = undefined;
var file_writer: std.Io.File.Writer = undefined;
var writer: *std.Io.Writer = undefined;
var log_io: std.Io = undefined;
var file_logging = false;
var log_lock: std.atomic.Value(bool) = .init(false);

// Aether's console entry shims can emit useful diagnostics before Engine.init
// has resolved the data directory and opened aether.log. On platforms where
// the debug-output channel is not visible (notably a standalone 3DS), retain
// those messages until the file logger is ready.
var bootstrap_log_buffer: [4096]u8 = undefined;
var bootstrap_log_len: usize = 0;
var bootstrap_log_truncated = false;

pub const Error = std.Io.File.OpenError;

fn lock() void {
    while (log_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlock() void {
    log_lock.store(false, .release);
}

fn flushFile(sync_to_storage: bool) void {
    if (!file_logging) return;

    writer.flush() catch {};
    if (sync_to_storage) file_log.sync(log_io) catch {};
}

/// PSP has no per-user data dir concept; the log sits at CWD (which is
/// where the EBOOT lives) regardless of what `data_dir` points at. Every
/// other platform routes through the engine-resolved data dir so
/// Finder-launched `.app` bundles don't try to write into read-only
/// bundle internals.
pub fn init(io: std.Io, data_dir: anytype) Error!void {
    lock();
    defer unlock();

    if (builtin.os.tag == .psp) {
        file_log = try std.Io.Dir.cwd().createFile(io, "ms0:/aether.log", .{ .truncate = true });
    } else {
        file_log = try data_dir.createFile(io, "aether.log", .{ .truncate = true });
    }
    file_writer = file_log.writer(io, &log_buffer);
    writer = &file_writer.interface;
    log_io = io;
    file_logging = true;

    flush_bootstrap_log();
}

pub fn deinit(io: std.Io) void {
    if (!file_logging) return;
    flushFile(true);
    file_log.close(io);
    file_logging = false;
}

pub fn flush() void {
    lock();
    defer unlock();

    flushFile(options.config.flush_logs);
}

pub fn aether_log_fn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    lock();
    defer unlock();

    const scope_prefix = "(" ++ @tagName(scope) ++ ") ";

    const prefix = scope_prefix ++ "[" ++ comptime level.asText() ++ "]: ";

    if (file_logging) {
        writer.print(prefix ++ format ++ "\n", args) catch {};
        if (options.config.flush_logs) flushFile(true);
    } else {
        append_bootstrap_log(prefix, format, args);
    }
    std.debug.print(prefix ++ format ++ "\n", args);
}

fn append_bootstrap_log(
    comptime prefix: []const u8,
    comptime format: []const u8,
    args: anytype,
) void {
    const written = std.fmt.bufPrint(
        bootstrap_log_buffer[bootstrap_log_len..],
        prefix ++ format ++ "\n",
        args,
    ) catch {
        bootstrap_log_truncated = true;
        return;
    };
    bootstrap_log_len += written.len;
}

fn flush_bootstrap_log() void {
    if (bootstrap_log_len != 0) {
        writer.writeAll(bootstrap_log_buffer[0..bootstrap_log_len]) catch {};
    }
    if (bootstrap_log_truncated) {
        writer.writeAll("(logger) [warning]: early log messages were truncated\n") catch {};
    }

    bootstrap_log_len = 0;
    bootstrap_log_truncated = false;
    flushFile(options.config.flush_logs);
}
