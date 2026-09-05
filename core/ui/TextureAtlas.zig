const std = @import("std");
const assert = std.debug.assert;

const snorm_uv_max: i32 = 32767;
const snorm_uv_steps: i32 = snorm_uv_max + 1;
// The extra max-edge step avoids UV 1.0 wrapping under repeat samplers.
const min_guard: u16 = 1;
const max_guard: u16 = 2;

/// Maps tiles to SNORM16 UVs in [0, 32767]. Dimensions must be powers of two.
pub const TextureAtlas = struct {
    col_log2: u5,
    row_log2: u5,
    min_guard_u: u16,
    min_guard_v: u16,
    max_guard_u: u16,
    max_guard_v: u16,

    pub fn init(res_x: u32, res_y: u32, rows: u32, cols: u32) TextureAtlas {
        assert(std.math.isPowerOfTwo(res_x));
        assert(std.math.isPowerOfTwo(res_y));
        return init_grid(rows, cols);
    }

    /// Normalized tile coordinates depend on the grid, not image resolution.
    pub fn init_grid(rows: u32, cols: u32) TextureAtlas {
        assert(std.math.isPowerOfTwo(rows));
        assert(std.math.isPowerOfTwo(cols));
        return .{
            .col_log2 = @intCast(@ctz(cols)),
            .row_log2 = @intCast(@ctz(rows)),
            .min_guard_u = min_guard,
            .min_guard_v = min_guard,
            .max_guard_u = max_guard,
            .max_guard_v = max_guard,
        };
    }

    pub fn tile_width(self: TextureAtlas) i16 {
        return @intCast((snorm_uv_steps >> self.col_log2) - @as(i32, self.min_guard_u) - @as(i32, self.max_guard_u));
    }

    pub fn tile_height(self: TextureAtlas) i16 {
        return @intCast((snorm_uv_steps >> self.row_log2) - @as(i32, self.min_guard_v) - @as(i32, self.max_guard_v));
    }

    pub fn tile_u(self: TextureAtlas, x: u32) i16 {
        assert(x < (@as(u32, 1) << self.col_log2));
        return @intCast(@as(i32, @intCast(x)) * (snorm_uv_steps >> self.col_log2) + @as(i32, self.min_guard_u));
    }

    pub fn tile_v(self: TextureAtlas, y: u32) i16 {
        assert(y < (@as(u32, 1) << self.row_log2));
        return @intCast(@as(i32, @intCast(y)) * (snorm_uv_steps >> self.row_log2) + @as(i32, self.min_guard_v));
    }
};

test "atlas guards keep the final tile below UV 1.0" {
    const atlas = TextureAtlas.init(256, 256, 16, 16);
    const expected_min: i16 = 1;
    const expected_max: i16 = 2;
    const stride: i16 = 2048;

    try std.testing.expectEqual(expected_min, atlas.tile_u(0));
    try std.testing.expectEqual(expected_min, atlas.tile_v(0));
    try std.testing.expectEqual(stride + expected_min, atlas.tile_u(1));
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tile_width());
    try std.testing.expectEqual(stride - expected_min - expected_max, atlas.tile_height());
    try std.testing.expectEqual(snorm_uv_steps - expected_max, atlas.tile_u(15) + atlas.tile_width());
}
