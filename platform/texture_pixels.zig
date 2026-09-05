pub const color_mode = @import("graphics/pixel_format.zig").PixelFormat.rgba8;
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

test "linear texture pixels preserve RGBA8 and row order" {
    const testing = @import("std").testing;
    var data: [16]u8 = @splat(0);
    const rgba = [4]u8{ 0x0F, 0x2B, 0x64, 0xE9 };
    write(&data, offset(2, 2, 1, 1), rgba);
    try testing.expectEqual(rgba, read(&data, 12));
    try testing.expectEqualSlices(u8, &@as([12]u8, @splat(0)), data[0..12]);
    var copied: [16]u8 = undefined;
    copy_from_rgba(&copied, &data);
    try testing.expectEqualSlices(u8, &data, &copied);
}
