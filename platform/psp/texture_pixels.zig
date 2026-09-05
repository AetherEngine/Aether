const linear = @import("../texture_pixels.zig");
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

test "PSP texture conversion preserves channels and quantizes to RGBA4444" {
    const testing = @import("std").testing;
    const rgba = [4]u8{ 0x0F, 0x2B, 0x64, 0xE9 };
    var data: [bytes_per_pixel]u8 = undefined;
    copy_from_rgba(&data, &rgba);
    try testing.expectEqual(if (compact) [4]u8{ 0, 0x22, 0x66, 0xEE } else rgba, read(&data, 0));
    if (compact) try testing.expectEqualSlices(u8, &.{ 0x20, 0xE6 }, &data);
}

test "PSP textures use linear storage below 8 KiB and GE blocks above it" {
    const testing = @import("std").testing;
    const width = 64;
    const height = 8192 / width / bytes_per_pixel;
    try testing.expectEqual(65 * bytes_per_pixel, offset(width, height / 2, 1, 1));
    try testing.expectEqual(16 + bytes_per_pixel, offset(width, height, 1, 1));
    try testing.expectEqual(128, offset(width, height, 16 / bytes_per_pixel, 0));
    try testing.expectEqual(width * bytes_per_pixel * 8, offset(width, height, 0, 8));
    try testing.expectEqual(8192 - bytes_per_pixel, offset(width, height, width - 1, height - 1));
}
