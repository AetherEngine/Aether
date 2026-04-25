const std = @import("std");
const builtin = @import("builtin");
const logger = @import("logger.zig");
const memory = @import("memory.zig");

pub const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;
pub const Image = @import("image.zig");
pub const MemoryConfig = memory.MemoryConfig;
pub const Pool = memory.Pool;
pub const Estimator = @import("estimator.zig").Estimator;
pub const Confidence = @import("estimator.zig").Confidence;
pub const BudgetContext = @import("budget_context.zig").BudgetContext;
pub const Thread = @import("thread.zig").Thread;
pub const ThreadConfig = @import("thread.zig").Config;
pub const ThreadPriority = @import("thread.zig").Priority;

comptime {
    std.testing.refAllDecls(@This());
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = logger.aether_log_fn,
};

pub const engine_logger = std.log.scoped(.engine);
pub const game_logger = std.log.scoped(.game);

pub fn ctx_to_self(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}
