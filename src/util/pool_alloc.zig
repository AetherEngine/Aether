//! Fixed-buffer pool allocator backed by an intrusive treap of free blocks.
//!
//! Buffer layout:
//!   [BlockHeader | payload] [BlockHeader | payload] ... [Sentinel]
//!
//! Every block boundary and user-data start is BLOCK_ALIGN-aligned.
//! Free blocks embed a `FreeTree.Node` at the start of their payload (intrusive).
//! The treap is keyed by (size, address): best_fit() is one O(log n) descent.
//!
//! alloc — O(log n): best_fit descent + optional split + one insertion
//! free  — O(log n): up to two coalesce removals + one insertion

const std   = @import("std");
const assert = std.debug.assert;

/// All block boundaries and user-data pointers are aligned to this.
pub const BLOCK_ALIGN: usize = 16;

/// Prepended to every block, free or allocated.
const BlockHeader = extern struct {
    /// Total block bytes including this header, always a multiple of BLOCK_ALIGN.
    /// Bit 0: 1 = allocated, 0 = free.
    size_flags: usize,
    /// Size of the immediately preceding physical block; 0 for the first block.
    prev_size: usize,
};

comptime {
    assert(@sizeOf(BlockHeader) == 16);
    assert(@alignOf(BlockHeader) == 8);
}

/// Treap key: sort primarily by block size (best-fit search), break ties by
/// address so every key is unique.
const Key = struct { size: usize, addr: usize };

fn cmp_key(a: Key, b: Key) std.math.Order {
    if (a.size != b.size) return std.math.order(a.size, b.size);
    return std.math.order(a.addr, b.addr);
}

const FreeTree = std.Treap(Key, cmp_key);

/// Minimum free-block size: header + intrusive treap node.
pub const MIN_BLOCK: usize = @sizeOf(BlockHeader) + @sizeOf(FreeTree.Node);

// ── block helpers ─────────────────────────────────────────────────────────────

inline fn blk_sz(h: *const BlockHeader) usize {
    return h.size_flags & ~@as(usize, 1);
}
inline fn blk_used(h: *const BlockHeader) bool {
    return (h.size_flags & 1) != 0;
}
inline fn blk_next(h: *BlockHeader) *BlockHeader {
    return @ptrFromInt(@intFromPtr(h) + blk_sz(h));
}
inline fn blk_node(h: *BlockHeader) *FreeTree.Node {
    return @ptrFromInt(@intFromPtr(h) + @sizeOf(BlockHeader));
}
inline fn node_blk(n: *FreeTree.Node) *BlockHeader {
    return @ptrFromInt(@intFromPtr(n) - @sizeOf(BlockHeader));
}
inline fn blk_key(h: *BlockHeader) Key {
    return .{ .size = blk_sz(h), .addr = @intFromPtr(h) };
}

// ── treap wrappers ────────────────────────────────────────────────────────────

fn tree_insert(tree: *FreeTree, h: *BlockHeader) void {
    var entry = tree.getEntryFor(blk_key(h));
    entry.set(blk_node(h));
}

fn tree_remove(tree: *FreeTree, h: *BlockHeader) void {
    var entry = tree.getEntryForExisting(blk_node(h));
    entry.set(null);
}

/// Walk the treap to find the smallest free block with size >= min_size.
/// O(log n) — the primary key is size, so we descend left when the current
/// node already qualifies and right when it's too small.
fn best_fit(tree: *FreeTree, min_size: usize) ?*BlockHeader {
    var best: ?*FreeTree.Node = null;
    var cur = tree.root;
    while (cur) |n| {
        if (n.key.size >= min_size) {
            best = n;
            cur = n.children[0]; // try smaller
        } else {
            cur = n.children[1]; // need larger
        }
    }
    return if (best) |n| node_blk(n) else null;
}

// ── public allocator ──────────────────────────────────────────────────────────

pub const PoolAlloc = struct {
    buf:    []u8,
    tree:   FreeTree,
    used:   usize,
    budget: usize,
    name:   []const u8,

    const vtable = std.mem.Allocator.VTable{
        .alloc  = alloc_fn,
        .resize = resize_fn,
        .remap  = remap_fn,
        .free   = free_fn,
    };

    pub fn init(buf: []u8, name: []const u8) PoolAlloc {
        // Advance the start to the next BLOCK_ALIGN boundary.
        const start = std.mem.alignForward(usize, @intFromPtr(buf.ptr), BLOCK_ALIGN);
        const end   = @intFromPtr(buf.ptr) + buf.len;
        const total = ((end - start) / BLOCK_ALIGN) * BLOCK_ALIGN;
        assert(total >= MIN_BLOCK + @sizeOf(BlockHeader));

        var self = PoolAlloc{
            .buf    = buf,
            .tree   = .{},
            .used   = 0,
            .budget = buf.len,
            .name   = name,
        };

        // One free block spanning the usable region, then an end sentinel.
        // Sentinel: size=0, used-bit set — stops forward coalescing at the edge.
        const free_sz = total - @sizeOf(BlockHeader);
        const main: *BlockHeader     = @ptrFromInt(start);
        main.*     = .{ .size_flags = free_sz,     .prev_size = 0       };
        const sent: *BlockHeader     = @ptrFromInt(start + free_sz);
        sent.*     = .{ .size_flags = 0 | 1,       .prev_size = free_sz };

        tree_insert(&self.tree, main);
        return self;
    }

    pub fn allocator(self: *PoolAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(self: *PoolAlloc) void {
        self.* = init(self.buf, self.name);
    }

    // ── vtable callbacks ──────────────────────────────────────────────────────

    fn alloc_fn(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *PoolAlloc = @ptrCast(@alignCast(ctx));

        if (alignment.toByteUnits() > BLOCK_ALIGN) {
            std.debug.panic("pool '{s}': unsupported alignment {d} (max {d})", .{
                self.name, alignment.toByteUnits(), BLOCK_ALIGN,
            });
        }

        // Round the request up to a full block size (header + payload, aligned).
        const need = roundup(@sizeOf(BlockHeader) + n, BLOCK_ALIGN);

        const h = best_fit(&self.tree, need) orelse {
            std.debug.panic(
                "pool '{s}': out of memory (used={d}, budget={d}, requested={d})",
                .{ self.name, self.used, self.budget, n },
            );
        };
        tree_remove(&self.tree, h);

        const found = blk_sz(h);
        if (found >= need + MIN_BLOCK) {
            // Split: keep `need` bytes here, return the remainder to the tree.
            const split: *BlockHeader = @ptrFromInt(@intFromPtr(h) + need);
            split.* = .{ .size_flags = found - need, .prev_size = need };
            blk_next(split).prev_size = found - need;
            tree_insert(&self.tree, split);
            h.size_flags = need | 1;
        } else {
            h.size_flags = found | 1;
        }

        blk_next(h).prev_size = blk_sz(h);
        self.used += blk_sz(h);

        return @ptrFromInt(@intFromPtr(h) + @sizeOf(BlockHeader));
    }

    fn resize_fn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) bool {
        return false;
    }

    fn remap_fn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free_fn(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *PoolAlloc = @ptrCast(@alignCast(ctx));

        // Recover the block header: user data starts exactly one header past it.
        var h: *BlockHeader = @ptrFromInt(@intFromPtr(buf.ptr) - @sizeOf(BlockHeader));
        assert(blk_used(h));

        const sz = blk_sz(h);
        self.used -= sz;
        h.size_flags = sz; // clear used bit

        // Coalesce forward with the next physical block if it is free.
        // The sentinel is always "used" (bit 0 set) so it stops coalescing.
        const nx = blk_next(h);
        if (!blk_used(nx)) {
            tree_remove(&self.tree, nx);
            const merged = sz + blk_sz(nx);
            h.size_flags = merged;
            blk_next(h).prev_size = merged;
        }

        // Coalesce backward with the previous physical block if it is free.
        if (h.prev_size != 0) {
            const pv: *BlockHeader = @ptrFromInt(@intFromPtr(h) - h.prev_size);
            if (!blk_used(pv)) {
                tree_remove(&self.tree, pv);
                const merged = blk_sz(pv) + blk_sz(h);
                pv.size_flags = merged;
                blk_next(pv).prev_size = merged;
                h = pv;
            }
        }

        tree_insert(&self.tree, h);
    }
};

inline fn roundup(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}
