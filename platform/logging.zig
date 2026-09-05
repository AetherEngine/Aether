//! PSP and 3DS use a worker so filesystem stalls never block log producers.

const std = @import("std");
const options = @import("options");

const use_worker_logger = switch (options.config.platform) {
    .nintendo_3ds, .psp => true,
    else => false,
};
const Backend = if (use_worker_logger) @import("logging/worker.zig") else @import("logging/sync.zig");

pub const Error = Backend.Error;
pub const deinit = Backend.deinit;
pub const flush = Backend.flush;
pub const aether_log_fn = Backend.aether_log_fn;

pub fn init(io: std.Io, data_dir: std.Io.Dir, allocator: std.mem.Allocator) Error!void {
    if (comptime use_worker_logger) {
        return Backend.init(io, data_dir, allocator);
    }
    return Backend.init(io, data_dir);
}
