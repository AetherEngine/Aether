const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const logger = @import("logger.zig");
const memory = @import("memory.zig");

pub const CircularBuffer = @import("circular_buffer.zig").CircularBuffer;
pub const Image = @import("image.zig");
pub const MemoryConfig = memory.MemoryConfig;
pub const Pool = memory.Pool;
pub const Estimator = @import("estimator.zig").Estimator;
pub const Confidence = @import("estimator.zig").Confidence;
pub const BudgetContext = @import("budget_context.zig").BudgetContext;

comptime {
    std.testing.refAllDecls(@This());
}

// -- category tracker (wrapper allocator with per-category accounting) --------

const CategoryTracker = struct {
    inner: std.mem.Allocator,
    used: usize,
    budget: usize,
    name: []const u8,

    const vtab = std.mem.Allocator.VTable{
        .alloc = tracked_alloc,
        .resize = tracked_resize,
        .remap = tracked_remap,
        .free = tracked_free,
    };

    fn tracked_alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CategoryTracker = @ptrCast(@alignCast(ctx));
        if (self.used + len > self.budget) return null;
        const result = self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr) orelse return null;
        self.used += len;
        return result;
    }

    fn tracked_free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CategoryTracker = @ptrCast(@alignCast(ctx));
        self.inner.vtable.free(self.inner.ptr, buf, alignment, ret_addr);
        self.used -= buf.len;
    }

    fn tracked_resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CategoryTracker = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const grow = new_len - buf.len;
            if (self.used + grow > self.budget) return false;
        }
        const ok = self.inner.vtable.resize(self.inner.ptr, buf, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len >= buf.len) {
                self.used += new_len - buf.len;
            } else {
                self.used -= buf.len - new_len;
            }
        }
        return ok;
    }

    fn tracked_remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CategoryTracker = @ptrCast(@alignCast(ctx));
        const result = self.inner.vtable.remap(self.inner.ptr, buf, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len >= buf.len) {
                self.used += new_len - buf.len;
            } else {
                self.used -= buf.len - new_len;
            }
        }
        return result;
    }

    fn get_allocator(self: *CategoryTracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtab };
    }
};

// -- module state -------------------------------------------------------------

var initialized = false;
var pool: memory.PoolAlloc = undefined;
var trackers: [@typeInfo(Pool).@"enum".fields.len]CategoryTracker = undefined;
var _io: std.Io = undefined;

pub fn io() std.Io {
    assert(initialized);
    return _io;
}

pub const std_options: std.Options = .{
    .log_level = if (builtin.mode == .Debug) .debug else .info,
    .logFn = logger.aether_log_fn,
};

pub const engine_logger = std.log.scoped(.engine);
pub const game_logger = std.log.scoped(.game);

pub fn init(sys_io: std.Io, mem: []u8, config: MemoryConfig) !void {
    assert(!initialized);
    assert(config.total() <= mem.len);

    _io = sys_io;

    pool = memory.PoolAlloc.init(mem, "main");
    const inner = pool.allocator();

    inline for (std.meta.fields(Pool), 0..) |f, i| {
        trackers[i] = .{
            .inner = inner,
            .used = 0,
            .budget = @field(config, f.name),
            .name = f.name,
        };
    }

    try logger.init(_io);
    initialized = true;

    assert(initialized);
}

pub fn deinit() void {
    assert(initialized);

    logger.deinit(_io);
    initialized = false;

    assert(!initialized);
}

pub fn allocator(p: Pool) std.mem.Allocator {
    assert(initialized);
    return trackers[@intFromEnum(p)].get_allocator();
}

pub fn pool_used(p: Pool) usize {
    return trackers[@intFromEnum(p)].used;
}

pub fn pool_budget(p: Pool) usize {
    return trackers[@intFromEnum(p)].budget;
}

pub fn pool_remaining(p: Pool) usize {
    return pool_budget(p) - pool_used(p);
}

pub fn set_budget(p: Pool, new_budget: usize) void {
    trackers[@intFromEnum(p)].budget = new_budget;
}

pub fn total_used() usize {
    return pool.used;
}

pub fn total_budget() usize {
    return pool.budget;
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
    engine_logger.info("  total: {}/{} bytes ({d:.3}/{d:.3} MiB)", .{
        pool.used,
        pool.budget,
        @as(f64, @floatFromInt(pool.used)) / mib,
        @as(f64, @floatFromInt(pool.budget)) / mib,
    });
    engine_logger.info("--------------------", .{});
}

pub fn ctx_to_self(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}
