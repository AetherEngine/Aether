pub const color_mode = @import("pixel_format.zig").PixelFormat.rgba8;
pub const bytes_per_pixel: u32 = 4;

pub fn copy_from_rgba(dst: []u8, src: []const u8) void {
    @memcpy(dst, src[0..dst.len]);
}

pub fn offset(width: u32, height: u32, x: u32, y: u32) usize {
    _ = height;
    return (@as(usize, y) * width + x) * bytes_per_pixel;
}

pub fn read(data: []const u8, index: usize) [4]u8 {
    return data[index..][0..4].*;
}

pub fn write(data: []u8, index: usize, rgba: [4]u8) void {
    data[index..][0..4].* = rgba;
}
