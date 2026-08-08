//! Public logger facade.
//!
//! Keep the established synchronous logger on every platform except Nintendo
//! 3DS. The 3DS implementation is deliberately isolated because filesystem
//! requests can block on an ARM11 <-> ARM9 round trip and must not run on the
//! main or audio threads.

const std = @import("std");
const options = @import("options");

const use_3ds_worker = options.config.platform == .nintendo_3ds;
const Sync = if (use_3ds_worker) void else @import("logger_sync.zig");
const N3ds = if (use_3ds_worker) @import("logger_3ds.zig") else void;

pub const Error = if (use_3ds_worker) N3ds.Error else Sync.Error;

pub fn init(io: std.Io, data_dir: std.Io.Dir, allocator: std.mem.Allocator) Error!void {
    if (comptime use_3ds_worker) {
        return N3ds.init(io, data_dir, allocator);
    }
    return Sync.init(io, data_dir);
}

pub fn deinit(io: std.Io) void {
    if (comptime use_3ds_worker) {
        N3ds.deinit(io);
        return;
    }
    Sync.deinit(io);
}

pub fn flush() void {
    if (comptime use_3ds_worker) {
        N3ds.flush();
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
    if (comptime use_3ds_worker) {
        return N3ds.aether_log_fn(level, scope, format, args);
    }
    return Sync.aether_log_fn(level, scope, format, args);
}
