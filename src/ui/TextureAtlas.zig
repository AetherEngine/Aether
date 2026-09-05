const std = @import("std");
const assert = std.debug.assert;

const snorm_uv_max: i32 = 32767;
const snorm_uv_steps: i32 = snorm_uv_max + 1;
// Avoid exact atlas boundaries without visibly cropping the source tile. The
// max edge uses one extra step so the last atlas tile never emits SNORM 32767,
// which repeat samplers treat as UV 1.0.
const min_guard: u16 = 1;
const max_guard: u16 = 2;

/// Maps integer tile indices to SNORM16 UV coordinates for a rectangular texture atlas.
/// SNORM16 range [0, 32767] corresponds to UV [0, 1].
/// All dimensions must be powers of two.
pub const TextureAtlas = struct {
    col_log2: u5,
    row_log2: u5,
    min_guard_u: u16, // left/top guard in SNORM16 units
    min_guard_v: u16,
    max_guard_u: u16, // right/bottom guard in SNORM16 units
    max_guard_v: u16,

    pub fn init(res_x: u32, res_y: u32, rows: u32, cols: u32) TextureAtlas {
        assert(std.math.isPowerOfTwo(res_x));
        assert(std.math.isPowerOfTwo(res_y));
        assert(std.math.isPowerOfTwo(rows));
        assert(std.math.isPowerOfTwo(cols));
        const guards = edge_guards();
        return .{
            .col_log2 = @intCast(@ctz(cols)),
            .row_log2 = @intCast(@ctz(rows)),
            .min_guard_u = guards.min,
            .min_guard_v = guards.min,
            .max_guard_u = guards.max,
            .max_guard_v = guards.max,
        };
    }

    /// Width of one tile in SNORM16 units after applying edge guards.
    pub fn tile_width(self: TextureAtlas) i16 {
        return @intCast(self.tile_span_u() - @as(i32, self.min_guard_u) - @as(i32, self.max_guard_u));
    }

    /// Height of one tile in SNORM16 units after applying edge guards.
    pub fn tile_height(self: TextureAtlas) i16 {
        return @intCast(self.tile_span_v() - @as(i32, self.min_guard_v) - @as(i32, self.max_guard_v));
    }

    /// SNORM16 U coordinate for the left edge of tile column x.
    pub fn tile_u(self: TextureAtlas, x: u32) i16 {
        assert(x < (@as(u32, 1) << self.col_log2));
        return @intCast(@as(i32, @intCast(x)) * self.tile_span_u() + @as(i32, self.min_guard_u));
    }

    /// SNORM16 V coordinate for the top edge of tile row y.
    pub fn tile_v(self: TextureAtlas, y: u32) i16 {
        assert(y < (@as(u32, 1) << self.row_log2));
        return @intCast(@as(i32, @intCast(y)) * self.tile_span_v() + @as(i32, self.min_guard_v));
    }

    fn tile_span_u(self: TextureAtlas) i32 {
        return snorm_uv_steps >> self.col_log2;
    }

    fn tile_span_v(self: TextureAtlas) i32 {
        return snorm_uv_steps >> self.row_log2;
    }
};

const EdgeGuards = struct {
    min: u16,
    max: u16,
};

fn edge_guards() EdgeGuards {
    return .{ .min = min_guard, .max = max_guard };
}

test "default atlas inset follows platform" {
    const atlas = TextureAtlas.init(256, 256, 16, 16);
    const guards = edge_guards();
    const expected_min: i16 = @intCast(guards.min);
    const expected_max: i16 = @intCast(guards.max);
    const stride: i16 = 2048;

    try std.testing.expectEqual(expected_min, atlas.tile_u(0));
    try std.testing.expectEqual(expected_min, atlas.tile_v(0));
    try std.testing.expectEqual(stride + expected_min, atlas.tile_u(1));
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tile_width());
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tile_height());
    try std.testing.expectEqual(snorm_uv_steps - expected_max, atlas.tile_u(15) + atlas.tile_width());
}
