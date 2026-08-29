//! Public logger facade.
//!
//! Nintendo 3DS and PSP route log messages through a worker thread: on both
//! platforms filesystem requests can block (3DS ARM11 <-> ARM9 round trip;
//! PSP async-I/O completion threads run one priority step below the caller,
//! so a non-tracked thread that performs file I/O while holding the logger's
//! spinlock can starve them). The worker owns every file operation and never
//! runs on a producer thread.

const std = @import("std");
const options = @import("options");

const use_worker_logger = switch (options.config.platform) {
    .nintendo_3ds, .psp => true,
    else => false,
};
const Sync = if (use_worker_logger) void else @import("logger_sync.zig");
const Worker = if (use_worker_logger) @import("logger_3ds.zig") else void;

pub const Error = if (use_worker_logger) Worker.Error else Sync.Error;

pub fn init(io: std.Io, data_dir: std.Io.Dir, allocator: std.mem.Allocator) Error!void {
    if (comptime use_worker_logger) {
        return Worker.init(io, data_dir, allocator);
    }
    return Sync.init(io, data_dir);
}

pub fn deinit(io: std.Io) void {
    if (comptime use_worker_logger) {
        Worker.deinit(io);
        return;
    }
    Sync.deinit(io);
}

pub fn flush() void {
    if (comptime use_worker_logger) {
        Worker.flush();
        return;
    }
    Sync.flush();
}

pub fn aether_log_fn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (comptime use_worker_logger) {
        return Worker.aether_log_fn(level, scope, format, args);
    }
    return Sync.aether_log_fn(level, scope, format, args);
}
