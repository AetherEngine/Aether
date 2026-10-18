const std = @import("std");
const assert = std.debug.assert;
const UvRegion = @import("billboard_batcher.zig").UvRegion;
const SpriteSheet = @This();

const snorm_uv_max: u32 = 32767;

// Used to prevent sampling precision errors, notably most observed on PSP.
pub const edge_inset: f32 = 1.0 / 16.0;

/// Size of the whole texture in pixels.
width: u16,
height: u16,

/// Size of one cell in pixels.
cell_width: u16,
cell_height: u16,

/// Whole cells per row.
pub fn columns(self: SpriteSheet) u16 {
    return self.width / self.cell_width;
}

/// Whole cells per column.
pub fn rows(self: SpriteSheet) u16 {
    return self.height / self.cell_height;
}

/// The cell at `column`, `row`, counted from the top-left.
pub fn cell(self: SpriteSheet, column: u16, row: u16) UvRegion {
    self.assert_cell(column, row);

    const x: u32 = @as(u32, column) * self.cell_width;
    const y: u32 = @as(u32, row) * self.cell_height;
    return .{
        .min = .{ to_uv(x, self.width), to_uv(y, self.height) },
        .max = .{
            to_uv(x + self.cell_width, self.width),
            to_uv(y + self.cell_height, self.height),
        },
    };
}

/// A point inside the cell at `column`, `row`, where `u`, `v` run 0 to 1 across
/// it. Clamped `edge_inset` texels inside the cell.
pub fn point(self: SpriteSheet, column: u16, row: u16, u: f32, v: f32) [2]i16 {
    self.assert_cell(column, row);

    const w: f32 = @floatFromInt(self.cell_width);
    const h: f32 = @floatFromInt(self.cell_height);

    const column_f: f32 = @floatFromInt(column);
    const row_f: f32 = @floatFromInt(row);

    const x = column_f * w + std.math.clamp(u * w, edge_inset, w - edge_inset);
    const y = row_f * h + std.math.clamp(v * h, edge_inset, h - edge_inset);

    return .{
        to_uv_f(x, self.width),
        to_uv_f(y, self.height),
    };
}

/// How big one cell is drawn, in world units, at `pixels_per_unit` texels per
/// world unit.
pub fn cell_world_size(self: SpriteSheet, pixels_per_unit: f32) [2]f32 {
    assert(pixels_per_unit > 0);

    const width: f32 = @floatFromInt(self.cell_width);
    const height: f32 = @floatFromInt(self.cell_height);

    return .{
        width / pixels_per_unit,
        height / pixels_per_unit,
    };
}

fn assert_cell(self: SpriteSheet, column: u16, row: u16) void {
    assert(self.cell_width > 0 and self.cell_height > 0);
    assert(column < self.columns());
    assert(row < self.rows());
}

fn to_uv(pixel: u32, size: u16) i16 {
    return @intCast(pixel * snorm_uv_max / size);
}

fn to_uv_f(pixel: f32, size: u16) i16 {
    const max: f32 = @floatFromInt(snorm_uv_max);
    const size_f: f32 = @floatFromInt(size);
    return @intFromFloat(@round(pixel / size_f) * max);
}
