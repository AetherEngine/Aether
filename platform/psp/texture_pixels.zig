const linear = @import("../graphics/texture_pixels.zig");
const compact = @import("options").config.psp_display_mode == .rgb565;

pub const color_mode = if (compact) @import("../graphics/pixel_format.zig").PixelFormat.rgba4444 else linear.color_mode;
pub const bytes_per_pixel: u32 = if (compact) 2 else 4;

pub fn copy_from_rgba(dst: []u8, src: []const u8) void {
    if (!compact) return linear.copy_from_rgba(dst, src);
    for (0..dst.len / bytes_per_pixel) |i| write(dst, i * bytes_per_pixel, src[i * 4 ..][0..4].*);
}

pub fn offset(width: u32, height: u32, x: u32, y: u32) usize {
    if (width * bytes_per_pixel * height >= 8 * 1024) return swizzled_offset(x, y, width);
    return (@as(usize, y) * width + x) * bytes_per_pixel;
}

/// GE texture blocks are 16 bytes wide and 8 rows tall.
pub fn swizzled_offset(x: u32, y: u32, width: u32) usize {
    const byte_x = x * bytes_per_pixel;
    const blocks_per_row = width * bytes_per_pixel / 16;
    return (y / 8 * blocks_per_row + byte_x / 16) * 128 + y % 8 * 16 + byte_x % 16;
}

pub fn read(data: []const u8, index: usize) [4]u8 {
    if (!compact) return linear.read(data, index);
    const pixel = @as(u16, data[index]) | (@as(u16, data[index + 1]) << 8);
    var rgba: [4]u8 = undefined;
    inline for (0..4) |i| rgba[i] = @as(u8, @intCast((pixel >> (i * 4)) & 0xF)) * 17;
    return rgba;
}

pub fn write(data: []u8, index: usize, rgba: [4]u8) void {
    if (!compact) return linear.write(data, index, rgba);
    data[index] = (rgba[0] >> 4) | (rgba[1] & 0xF0);
    data[index + 1] = (rgba[2] >> 4) | (rgba[3] & 0xF0);
}
