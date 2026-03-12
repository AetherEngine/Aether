const pool_alloc = @import("pool_alloc.zig");

pub const MemoryConfig = struct {
    render:  usize,
    audio:   usize,
    game:    usize,
    user:    usize,
    scratch: usize,

    pub fn total(self: MemoryConfig) usize {
        return self.render + self.audio + self.game + self.user + self.scratch;
    }
};

pub const Pool = enum { render, audio, game, user, scratch };

pub const PoolAllocator = pool_alloc.PoolAlloc;
