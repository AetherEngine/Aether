const pool_alloc = @import("pool_alloc.zig");

pub const MemoryConfig = struct {
    render:  usize,
    audio:   usize,
    game:    usize,
    user:    usize,

    pub fn total(self: MemoryConfig) usize {
        return self.render + self.audio + self.game + self.user;
    }
};

pub const Pool = enum { render, audio, game, user };

pub const PoolAlloc = pool_alloc.PoolAlloc;
