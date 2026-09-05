//! Low-level primitives shared by backends and the engine API.

const std = @import("std");
const builtin = @import("builtin");
const logging = @import("../logging.zig");

pub const CircularBufferType = @import("circular_buffer.zig").CircularBufferType;
pub const HandleType = @import("handle.zig").HandleType;
pub const ResourceTableType = @import("handle.zig").ResourceTableType;
pub const PoolAlloc = @import("pool_alloc.zig").PoolAlloc;

pub const std_options: std.Options = if (@hasField(std.Options, "page_size_min")) .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = logging.aether_log_fn,
    .page_size_min = if (builtin.os.tag == .freestanding) 4096 else null,
    .page_size_max = if (builtin.os.tag == .freestanding) 4096 else null,
} else .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = logging.aether_log_fn,
};

pub const engine_logger = std.log.scoped(.engine);
pub const game_logger = std.log.scoped(.game);

pub fn ctx_to_self(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

pub fn panic_invalid_handle(comptime subsystem: []const u8, comptime operation: []const u8, handle: anytype) noreturn {
    std.debug.panic(subsystem ++ ": " ++ operation ++ ": invalid handle index={} generation={}", .{
        handle.raw_index(),
        handle.generation,
    });
}

comptime {
    std.testing.refAllDecls(@This());
}
