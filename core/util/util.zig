const std = @import("std");
const memory = @import("memory.zig");
const platform_util = @import("platform").util;
const platform_thread = @import("platform").thread;

pub const CircularBufferType = platform_util.CircularBufferType;
pub const HandleType = platform_util.HandleType;
pub const ResourceTableType = platform_util.ResourceTableType;
pub const Image = @import("image.zig");
pub const MemoryConfig = memory.MemoryConfig;
pub const Pool = memory.Pool;
pub const Estimator = @import("estimator.zig").Estimator;
pub const Confidence = @import("estimator.zig").Confidence;
pub const BudgetContext = @import("budget_context.zig").BudgetContext;
pub const Thread = platform_thread.Thread;
pub const ThreadConfig = platform_thread.Config;
pub const ThreadPriority = platform_thread.Priority;

comptime {
    std.testing.refAllDecls(@This());
}

pub const std_options = platform_util.std_options;
pub const engine_logger = platform_util.engine_logger;
pub const game_logger = platform_util.game_logger;
pub const ctx_to_self = platform_util.ctx_to_self;
pub const panic_invalid_handle = platform_util.panic_invalid_handle;
