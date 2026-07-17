const pool_alloc = @import("pool_alloc.zig");

pub const MemoryConfig = struct {
    render: usize,
    audio: usize,
    game: usize,
    user: usize,

    pub fn total(self: *const MemoryConfig) usize {
        return self.render + self.audio + self.game + self.user;
    }
};

pub const Pool = enum { render, audio, game, user };
pub const POOL_COUNT = @typeInfo(Pool).@"enum".fields.len;

/// A named set of movable accounting budgets over the engine's one shared
/// backing memory pool.
pub const MemoryProfile = struct {
    name: []const u8,
    budgets: MemoryConfig,
};

pub const PoolDiagnostics = struct {
    name: []const u8,
    used: usize,
    budget: usize,
    remaining_budget: usize,
    high_water: usize,
    allocation_count: usize,
    last_failed_request: ?usize,
};

pub const MemoryDiagnostics = struct {
    profile_name: ?[]const u8,
    pools: [POOL_COUNT]PoolDiagnostics,
    physical_used: usize,
    physical_capacity: usize,
    physical_largest_free_run: usize,
    total_budget: usize,
};

pub const PoolAlloc = pool_alloc.PoolAlloc;
