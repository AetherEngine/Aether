const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const logger = @import("logger.zig");
const memory = @import("memory.zig");

pub const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;
pub const Image = @import("image.zig");
pub const MemoryConfig = memory.MemoryConfig;
pub const Pool = memory.Pool;
pub const Allocator = memory.PoolAllocator;

comptime {
    std.testing.refAllDecls(@This());
}

var initialized = false;
var pools: [@typeInfo(Pool).@"enum".fields.len]memory.PoolAllocator = undefined;

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = logger.aether_log_fn,
};

pub const engine_logger = std.log.scoped(.engine);
pub const game_logger = std.log.scoped(.game);

pub fn init(io: std.Io, mem: []u8, config: MemoryConfig) !void {
    assert(!initialized);
    assert(config.total() <= mem.len);

    var offset: usize = 0;
    inline for (std.meta.fields(Pool), 0..) |f, i| {
        const budget = @field(config, f.name);
        pools[i] = memory.PoolAllocator.init(mem[offset .. offset + budget], f.name);
        offset += budget;
    }

    try logger.init(io);
    initialized = true;

    assert(initialized);
}

pub fn deinit(io: std.Io) void {
    assert(initialized);

    logger.deinit(io);
    initialized = false;

    assert(!initialized);
}

pub fn allocator(pool: Pool) std.mem.Allocator {
    assert(initialized);
    return pools[@intFromEnum(pool)].allocator();
}

pub fn pool_used(pool: Pool) usize {
    return pools[@intFromEnum(pool)].used;
}

pub fn pool_budget(pool: Pool) usize {
    return pools[@intFromEnum(pool)].budget;
}

pub fn pool_remaining(pool: Pool) usize {
    return pool_budget(pool) - pool_used(pool);
}

pub fn scratch_reset() void {
    pools[@intFromEnum(Pool.scratch)].reset();
}

pub fn pool_slice(pool: Pool) []u8 {
    return pools[@intFromEnum(pool)].buf;
}

pub fn report() void {
    const mib = 1024.0 * 1024.0;
    engine_logger.info("--- memory pools ---", .{});
    inline for (std.meta.fields(Pool)) |f| {
        const p: Pool = @enumFromInt(f.value);
        const used = pool_used(p);
        const budget = pool_budget(p);
        const remaining = pool_remaining(p);
        engine_logger.info("  {s}: {}/{} bytes ({d:.3}/{d:.3} MiB, {} remaining)", .{
            f.name,
            used,
            budget,
            @as(f64, @floatFromInt(used)) / mib,
            @as(f64, @floatFromInt(budget)) / mib,
            remaining,
        });
    }
    engine_logger.info("--------------------", .{});
}

pub fn ctx_to_self(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}
