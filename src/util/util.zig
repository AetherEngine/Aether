const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const GPA = std.heap.GeneralPurposeAllocator(.{});
const logger = @import("logger.zig");
pub const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;

var initialized = false;
var gpa: GPA = undefined;

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = logger.aether_log_fn,
};

pub const engine_logger = std.log.scoped(.engine);
pub const game_logger = std.log.scoped(.game);

pub fn init(io: std.Io) !void {
    assert(!initialized);

    gpa = GPA{};
    try logger.init(io);
    initialized = true;

    assert(initialized);
}

pub fn deinit(io: std.Io) void {
    assert(initialized);

    logger.deinit(io);
    _ = gpa.deinit();
    initialized = false;

    assert(!initialized);
}

pub fn allocator() std.mem.Allocator {
    assert(initialized);

    return gpa.allocator();
}

pub fn ctx_to_self(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}
