//! Fixed-buffer pool allocator backed by a two-level bitmap of free blocks.
//!
//! Buffer layout:
//!   [L0 bitmap (u32[])] [L1 summary (u32[])] [padding] [data blocks...]
//!
//! Every data block is BLOCK_SIZE-aligned (and therefore BLOCK_ALIGN-aligned).
//! L0 has one bit per block (1 = free, 0 = allocated).
//! L1 has one bit per L0 word (1 = at least one free block in that group).
//!
//! Over-aligned requests (alignment > BLOCK_SIZE) are handled by constraining
//! the starting block index to a multiple of (alignment / BLOCK_SIZE).
//!
//! alloc — O(1) single-block via L1→L0 descent; O(n/32) multi-block scan
//! free  — O(1): set bits + update summary
//! resize — O(1): test/set adjacent bits

const std = @import("std");
const assert = std.debug.assert;

/// All returned user-data pointers satisfy at least this alignment.
pub const BLOCK_ALIGN: usize = 16;

/// Allocation granularity. Every allocation is rounded up to a multiple of this.
pub const BLOCK_SIZE: usize = 64;

const WORD_BITS: u32 = 32;
const WORD_MASK: u32 = WORD_BITS - 1;

comptime {
    assert(BLOCK_SIZE >= BLOCK_ALIGN);
    assert(std.math.isPowerOfTwo(BLOCK_SIZE));
    assert(std.math.isPowerOfTwo(BLOCK_ALIGN));
}

// -- helpers ------------------------------------------------------------------

inline fn div_ceil(a: usize, b: usize) usize {
    return (a + b - 1) / b;
}

inline fn roundup(n: usize, a: usize) usize {
    return (n + a - 1) & ~(a - 1);
}

// -- public allocator ---------------------------------------------------------

pub const PoolAlloc = struct {
    buf: []u8,
    l0: [*]u32,
    l1: [*]u32,
    data: [*]u8,
    total_blocks: u32,
    l0_words: u32,
    l1_words: u32,
    hint: u32,
    used: usize,
    budget: usize,
    name: []const u8,

    const vtable = std.mem.Allocator.VTable{
        .alloc = alloc_fn,
        .resize = resize_fn,
        .remap = remap_fn,
        .free = free_fn,
    };

    pub fn init(buf: []u8, name: []const u8) PoolAlloc {
        const buf_start = @intFromPtr(buf.ptr);
        const buf_end = buf_start + buf.len;

        // We need to figure out how many data blocks fit after carving out
        // bitmap metadata from the front.  Iterate once: guess total_blocks
        // from the full buffer, compute metadata size, recompute.
        const aligned_start = std.mem.alignForward(usize, buf_start, BLOCK_ALIGN);
        const usable = buf_end - aligned_start;

        // Upper bound on blocks (ignoring metadata).
        var total_blocks: u32 = @intCast(usable / BLOCK_SIZE);
        // Shrink until metadata + data fits.
        while (total_blocks > 0) {
            const l0w = div_ceil(total_blocks, WORD_BITS);
            const l1w = div_ceil(l0w, WORD_BITS);
            const meta_bytes = (l0w + l1w) * @sizeOf(u32);
            const data_start = std.mem.alignForward(usize, aligned_start + meta_bytes, BLOCK_SIZE);
            const data_bytes = if (buf_end >= data_start) buf_end - data_start else 0;
            const fits: u32 = @intCast(data_bytes / BLOCK_SIZE);
            if (fits >= total_blocks) break;
            total_blocks = fits;
        }
        assert(total_blocks > 0);

        const l0_words: u32 = @intCast(div_ceil(total_blocks, WORD_BITS));
        const l1_words: u32 = @intCast(div_ceil(l0_words, WORD_BITS));
        const meta_bytes = (l0_words + l1_words) * @sizeOf(u32);
        const data_start = std.mem.alignForward(usize, aligned_start + meta_bytes, BLOCK_SIZE);

        var self = PoolAlloc{
            .buf = buf,
            .l0 = @ptrFromInt(aligned_start),
            .l1 = @ptrFromInt(aligned_start + l0_words * @sizeOf(u32)),
            .data = @ptrFromInt(data_start),
            .total_blocks = total_blocks,
            .l0_words = l0_words,
            .l1_words = l1_words,
            .hint = 0,
            .used = 0,
            .budget = buf.len,
            .name = name,
        };

        self.reset_bitmaps();
        return self;
    }

    fn reset_bitmaps(self: *PoolAlloc) void {
        // Set all L0 bits to 1 (free).
        const full_words = self.total_blocks / WORD_BITS;
        const tail_bits: u5 = @intCast(self.total_blocks & WORD_MASK);

        var i: u32 = 0;
        while (i < full_words) : (i += 1) {
            self.l0[i] = 0xFFFF_FFFF;
        }
        // Last partial word: only set bits for existing blocks.
        if (tail_bits > 0) {
            self.l0[full_words] = (@as(u32, 1) << tail_bits) - 1;
            i = full_words + 1;
        }
        // Zero any remaining L0 words (shouldn't exist, but be safe).
        while (i < self.l0_words) : (i += 1) {
            self.l0[i] = 0;
        }

        // Build L1 from L0.
        var li: u32 = 0;
        while (li < self.l1_words) : (li += 1) {
            var summary: u32 = 0;
            var bit: u5 = 0;
            while (true) : (bit += 1) {
                const l0_idx = li * WORD_BITS + bit;
                if (l0_idx >= self.l0_words) break;
                if (self.l0[l0_idx] != 0) {
                    summary |= @as(u32, 1) << bit;
                }
                if (bit == 31) break;
            }
            self.l1[li] = summary;
        }
    }

    pub fn allocator(self: *PoolAlloc) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn reset(self: *PoolAlloc) void {
        self.used = 0;
        self.hint = 0;
        self.reset_bitmaps();
    }

    // -- internal: bit manipulation -------------------------------------------

    /// Clear bit `bit` in L0 word `word_idx` and update L1.
    inline fn clear_bit(self: *PoolAlloc, word_idx: u32, bit: u5) void {
        self.l0[word_idx] &= ~(@as(u32, 1) << bit);
        if (self.l0[word_idx] == 0) {
            const l1_idx = word_idx / WORD_BITS;
            const l1_bit: u5 = @intCast(word_idx & WORD_MASK);
            self.l1[l1_idx] &= ~(@as(u32, 1) << l1_bit);
        }
    }

    /// Set bit `bit` in L0 word `word_idx` and update L1.
    inline fn set_bit(self: *PoolAlloc, word_idx: u32, bit: u5) void {
        self.l0[word_idx] |= @as(u32, 1) << bit;
        const l1_idx = word_idx / WORD_BITS;
        const l1_bit: u5 = @intCast(word_idx & WORD_MASK);
        self.l1[l1_idx] |= @as(u32, 1) << l1_bit;
    }

    /// Clear a contiguous range of blocks [start, start+count) in L0/L1.
    fn clear_range(self: *PoolAlloc, start: u32, count: u32) void {
        var blk = start;
        var remaining = count;
        while (remaining > 0) {
            const wi = blk / WORD_BITS;
            const bit: u5 = @intCast(blk & WORD_MASK);
            const bits_in_word = @min(remaining, @as(u32, WORD_BITS) - bit);

            const mask: u32 = if (bits_in_word == WORD_BITS)
                0xFFFF_FFFF
            else
                ((@as(u32, 1) << @as(u5, @intCast(bits_in_word))) - 1) << bit;

            self.l0[wi] &= ~mask;
            if (self.l0[wi] == 0) {
                const l1i = wi / WORD_BITS;
                const l1b: u5 = @intCast(wi & WORD_MASK);
                self.l1[l1i] &= ~(@as(u32, 1) << l1b);
            }

            blk += bits_in_word;
            remaining -= bits_in_word;
        }
    }

    /// Set a contiguous range of blocks [start, start+count) in L0/L1.
    fn set_range(self: *PoolAlloc, start: u32, count: u32) void {
        var blk = start;
        var remaining = count;
        while (remaining > 0) {
            const wi = blk / WORD_BITS;
            const bit: u5 = @intCast(blk & WORD_MASK);
            const bits_in_word = @min(remaining, @as(u32, WORD_BITS) - bit);

            const mask: u32 = if (bits_in_word == WORD_BITS)
                0xFFFF_FFFF
            else
                ((@as(u32, 1) << @as(u5, @intCast(bits_in_word))) - 1) << bit;

            self.l0[wi] |= mask;
            // Update L1: this word now has free blocks.
            const l1i = wi / WORD_BITS;
            const l1b: u5 = @intCast(wi & WORD_MASK);
            self.l1[l1i] |= @as(u32, 1) << l1b;

            blk += bits_in_word;
            remaining -= bits_in_word;
        }
    }

    /// Test whether `count` blocks starting at `start` are all free.
    fn test_range_free(self: *const PoolAlloc, start: u32, count: u32) bool {
        var blk = start;
        var remaining = count;
        while (remaining > 0) {
            const wi = blk / WORD_BITS;
            const bit: u5 = @intCast(blk & WORD_MASK);
            const bits_in_word = @min(remaining, @as(u32, WORD_BITS) - bit);

            const mask: u32 = if (bits_in_word == WORD_BITS)
                0xFFFF_FFFF
            else
                ((@as(u32, 1) << @as(u5, @intCast(bits_in_word))) - 1) << bit;

            if (self.l0[wi] & mask != mask) return false;

            blk += bits_in_word;
            remaining -= bits_in_word;
        }
        return true;
    }

    // -- internal: block finding -----------------------------------------------

    /// Find a single free block. Returns block index or null.
    fn find_single(self: *PoolAlloc) ?u32 {
        const start_l1 = self.hint / WORD_BITS;

        // Scan L1 from hint, wrapping around.
        var passes: u32 = 0;
        var l1i = start_l1;
        while (passes < 2) {
            if (l1i >= self.l1_words) {
                l1i = 0;
                passes += 1;
                if (passes >= 2) break;
                if (l1i > start_l1) break;
            }
            const l1w = self.l1[l1i];
            if (l1w == 0) {
                l1i += 1;
                continue;
            }

            // Find which L0 word has free blocks.
            const l1_bit: u5 = @truncate(@ctz(l1w));
            const l0i = l1i * WORD_BITS + l1_bit;
            if (l0i >= self.l0_words) {
                l1i += 1;
                continue;
            }
            const l0w = self.l0[l0i];
            if (l0w == 0) {
                // Stale L1 bit — shouldn't happen, but handle gracefully.
                l1i += 1;
                continue;
            }

            const blk_bit: u5 = @truncate(@ctz(l0w));
            const block_idx = l0i * WORD_BITS + blk_bit;
            if (block_idx >= self.total_blocks) {
                l1i += 1;
                continue;
            }

            self.hint = l0i;
            return block_idx;
        }
        return null;
    }

    /// Find `blocks_needed` contiguous free blocks with alignment constraint.
    /// `align_blocks` must be a power of 2 (1 for no constraint).
    fn find_run(self: *PoolAlloc, blocks_needed: u32, align_blocks: u32) ?u32 {
        if (blocks_needed == 1 and align_blocks <= 1) {
            return self.find_single();
        }

        const align_mask = align_blocks - 1;

        // Scan L0 from hint, then wrap around if needed.
        var start_wi = self.hint;
        var pass: u32 = 0;
        while (pass < 2) {
            var run_start: u32 = 0;
            var run_len: u32 = 0;
            var wi = start_wi;

            while (wi < self.l0_words) : (wi += 1) {
                const w = self.l0[wi];

                if (w == 0) {
                    // Fully allocated word — reset run.
                    run_len = 0;
                    continue;
                }

                if (w == 0xFFFF_FFFF) {
                    // Fully free word — extend or start run.
                    const word_base = wi * WORD_BITS;
                    if (run_len == 0) {
                        // Start a new run, aligned.
                        run_start = (word_base + align_mask) & ~align_mask;
                        if (run_start >= word_base + WORD_BITS) {
                            // Alignment pushed past this word.
                            continue;
                        }
                        run_len = word_base + WORD_BITS - run_start;
                    } else {
                        run_len += WORD_BITS;
                    }
                    // Clamp to total_blocks.
                    if (run_start + run_len > self.total_blocks) {
                        run_len = self.total_blocks - run_start;
                    }
                    if (run_len >= blocks_needed) {
                        self.hint = wi;
                        return run_start;
                    }
                    continue;
                }

                // Partial word — process bit by bit via sub-runs.
                const word_base = wi * WORD_BITS;

                // If we have a run from a previous word, try to extend it
                // with leading 1-bits of this word.
                if (run_len > 0) {
                    const leading_ones: u32 = @ctz(~w);
                    run_len += leading_ones;
                    if (run_start + run_len > self.total_blocks) {
                        run_len = self.total_blocks - run_start;
                    }
                    if (run_len >= blocks_needed) {
                        self.hint = wi;
                        return run_start;
                    }
                    if (leading_ones == WORD_BITS) continue; // handled above, but safety
                }

                // Scan for internal runs of 1-bits within this word.
                var remaining = w;
                var bit_off: u32 = 0;
                while (remaining != 0) {
                    // Skip zeros (allocated blocks).
                    const zeros: u32 = @ctz(remaining);
                    bit_off += zeros;
                    if (bit_off >= WORD_BITS) break;
                    remaining >>= @intCast(@min(zeros, 31));
                    if (zeros > 0 and zeros < 32) {
                        // We shifted past allocated blocks.
                    } else if (zeros >= 32) {
                        break;
                    }

                    // Count ones (free blocks).
                    const ones: u32 = @ctz(~remaining);
                    const candidate = word_base + bit_off;
                    const aligned_start = (candidate + align_mask) & ~align_mask;

                    if (aligned_start < candidate + ones) {
                        const effective = candidate + ones - aligned_start;
                        if (aligned_start + effective <= self.total_blocks and effective >= blocks_needed) {
                            self.hint = wi;
                            return aligned_start;
                        }
                        // Carry this run into the next word if it ends at bit 31.
                        run_start = aligned_start;
                        run_len = effective;
                    } else {
                        run_len = 0;
                    }

                    bit_off += ones;
                    if (ones >= 32 or bit_off >= WORD_BITS) break;
                    remaining >>= @as(u5, @intCast(ones));
                }

                // Check if the run extends to the end of this word.
                if (run_len > 0 and run_start + run_len != word_base + WORD_BITS) {
                    run_len = 0;
                }
            }

            // Wrap around for second pass.
            pass += 1;
            if (start_wi == 0) break; // Already scanned everything.
            // On wrap, scan from 0 up to where we started.
            start_wi = 0;
        }

        return null; // OOM
    }

    // -- vtable callbacks ------------------------------------------------------

    fn alloc_fn(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
        const self: *PoolAlloc = @ptrCast(@alignCast(ctx));
        if (n == 0) return null;

        const blocks_needed: u32 = @intCast(div_ceil(n, BLOCK_SIZE));
        const align_bytes = alignment.toByteUnits();
        const align_blocks: u32 = @intCast(@max(1, align_bytes / BLOCK_SIZE));

        const block_idx = self.find_run(blocks_needed, align_blocks) orelse return null;

        self.clear_range(block_idx, blocks_needed);
        self.used += @as(usize, blocks_needed) * BLOCK_SIZE;

        return self.data + @as(usize, block_idx) * BLOCK_SIZE;
    }

    fn free_fn(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
        const self: *PoolAlloc = @ptrCast(@alignCast(ctx));
        const offset = @intFromPtr(buf.ptr) - @intFromPtr(self.data);
        const block_idx: u32 = @intCast(offset / BLOCK_SIZE);
        const block_count: u32 = @intCast(div_ceil(buf.len, BLOCK_SIZE));

        self.set_range(block_idx, block_count);
        self.used -= @as(usize, block_count) * BLOCK_SIZE;

        // Pull hint back if we freed blocks before it.
        const wi = block_idx / WORD_BITS;
        if (wi < self.hint) {
            self.hint = wi;
        }
    }

    fn resize_fn(ctx: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
        const self: *PoolAlloc = @ptrCast(@alignCast(ctx));
        const offset = @intFromPtr(buf.ptr) - @intFromPtr(self.data);
        const block_idx: u32 = @intCast(offset / BLOCK_SIZE);
        const cur_blocks: u32 = @intCast(div_ceil(buf.len, BLOCK_SIZE));
        const new_blocks: u32 = @intCast(div_ceil(new_len, BLOCK_SIZE));

        if (new_blocks <= cur_blocks) {
            // Shrink: free trailing blocks.
            if (new_blocks < cur_blocks) {
                const freed = cur_blocks - new_blocks;
                self.set_range(block_idx + new_blocks, freed);
                self.used -= @as(usize, freed) * BLOCK_SIZE;
            }
            return true;
        }

        // Grow: check if blocks immediately after are free.
        const grow = new_blocks - cur_blocks;
        const grow_start = block_idx + cur_blocks;
        if (grow_start + grow > self.total_blocks) return false;
        if (!self.test_range_free(grow_start, grow)) return false;

        self.clear_range(grow_start, grow);
        self.used += @as(usize, grow) * BLOCK_SIZE;
        return true;
    }

    fn remap_fn(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }
};

// -- tests --------------------------------------------------------------------

const testing = std.testing;

test "pool_alloc: basic alloc and free" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const slice = try ally.alloc(u8, 64);
    try testing.expect(pa.used > 0);
    ally.free(slice);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: used tracks multiple allocations" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const a = try ally.alloc(u8, 64);
    const used_one = pa.used;
    const b = try ally.alloc(u8, 64);
    try testing.expect(pa.used > used_one);

    ally.free(a);
    ally.free(b);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: coalesce forward" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const a = try ally.alloc(u8, 64);
    const b = try ally.alloc(u8, 64);
    ally.free(a);
    ally.free(b);
    try testing.expectEqual(@as(usize, 0), pa.used);

    const big = try ally.alloc(u8, 128);
    ally.free(big);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: coalesce backward" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const a = try ally.alloc(u8, 64);
    const b = try ally.alloc(u8, 64);
    ally.free(b);
    ally.free(a);
    try testing.expectEqual(@as(usize, 0), pa.used);

    const big = try ally.alloc(u8, 128);
    ally.free(big);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: coalesce both directions" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const a = try ally.alloc(u8, 64);
    const b = try ally.alloc(u8, 64);
    const c = try ally.alloc(u8, 64);

    ally.free(a);
    ally.free(c);
    ally.free(b);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: returned pointers are BLOCK_ALIGN-aligned" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const a = try ally.alloc(u8, 1);
    const b = try ally.alloc(u8, 3);
    const c = try ally.alloc(u8, 17);
    const d = try ally.alloc(u8, 100);

    try testing.expectEqual(@as(usize, 0), @intFromPtr(a.ptr) % BLOCK_ALIGN);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(b.ptr) % BLOCK_ALIGN);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(c.ptr) % BLOCK_ALIGN);
    try testing.expectEqual(@as(usize, 0), @intFromPtr(d.ptr) % BLOCK_ALIGN);

    ally.free(a);
    ally.free(b);
    ally.free(c);
    ally.free(d);
}

test "pool_alloc: reset restores full capacity" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    _ = try ally.alloc(u8, 512);
    _ = try ally.alloc(u8, 256);
    try testing.expect(pa.used > 0);

    pa.reset();
    try testing.expectEqual(@as(usize, 0), pa.used);

    const big = try pa.allocator().alloc(u8, 1024);
    pa.allocator().free(big);
}

test "pool_alloc: resize shrink and grow" {
    var buf: [8192]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const a = try ally.alloc(u8, 64);
    const b = try ally.alloc(u8, 64);

    // Shrink: always succeeds (wastes the tail within the block)
    try testing.expect(ally.resize(a, 32));

    // Grow with occupied next block: must fail
    try testing.expect(!ally.resize(a, 256));

    // Free the next block, now growth can absorb it
    ally.free(b);
    try testing.expect(ally.resize(a, 100));

    ally.free(a);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: block contents are writable" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const ints = try ally.alloc(u32, 32);
    for (ints, 0..) |*v, i| v.* = @intCast(i * i);
    for (ints, 0..) |v, i| try testing.expectEqual(@as(u32, @intCast(i * i)), v);
    ally.free(ints);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: interleaved alloc and free" {
    var buf: [4096]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    const a = try ally.alloc(u8, 32);
    const b = try ally.alloc(u8, 32);
    ally.free(a);
    const c = try ally.alloc(u8, 32);
    const d = try ally.alloc(u8, 32);
    ally.free(c);
    ally.free(b);
    ally.free(d);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: over-alignment" {
    var buf: [8192]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();
    const over_align = comptime std.mem.Alignment.fromByteUnits(BLOCK_SIZE * 2);

    // Allocate with alignment > BLOCK_SIZE via raw vtable call.
    const raw = ally.vtable.alloc(ally.ptr, 64, over_align, 0) orelse
        return error.TestUnexpectedResult;

    // Verify alignment
    try testing.expectEqual(@as(usize, 0), @intFromPtr(raw) % (BLOCK_SIZE * 2));

    // Writable
    @memset(raw[0..64], 0xAB);
    try testing.expectEqual(@as(u8, 0xAB), raw[0]);

    // Free and verify cleanup
    ally.vtable.free(ally.ptr, raw[0..64], over_align, 0);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: OOM returns error" {
    var buf: [512]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    try testing.expectError(error.OutOfMemory, ally.alloc(u8, 4096));
}

test "pool_alloc: multi-block contiguous allocation" {
    var buf: [8192]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    // Allocate a chunk spanning multiple blocks.
    const big = try ally.alloc(u8, BLOCK_SIZE * 3);
    try testing.expectEqual(@as(usize, BLOCK_SIZE * 3), pa.used);

    // Verify pointer alignment.
    try testing.expectEqual(@as(usize, 0), @intFromPtr(big.ptr) % BLOCK_SIZE);

    // Write and read back.
    @memset(big, 0xCD);
    try testing.expectEqual(@as(u8, 0xCD), big[0]);
    try testing.expectEqual(@as(u8, 0xCD), big[BLOCK_SIZE * 3 - 1]);

    ally.free(big);
    try testing.expectEqual(@as(usize, 0), pa.used);
}

test "pool_alloc: fragmentation and reuse" {
    var buf: [8192]u8 align(BLOCK_SIZE) = undefined;
    var pa = PoolAlloc.init(buf[0..], "test");
    const ally = pa.allocator();

    // Allocate 4 single blocks.
    const a = try ally.alloc(u8, 1);
    const b = try ally.alloc(u8, 1);
    const c = try ally.alloc(u8, 1);
    const d = try ally.alloc(u8, 1);

    // Free alternating to create fragmentation.
    ally.free(b);
    ally.free(d);

    // Should still be able to allocate single blocks in the gaps.
    const e = try ally.alloc(u8, 1);
    const f = try ally.alloc(u8, 1);

    ally.free(a);
    ally.free(c);
    ally.free(e);
    ally.free(f);
    try testing.expectEqual(@as(usize, 0), pa.used);
}
