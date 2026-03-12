const std = @import("std");
const Image = @import("../util/image.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;

const Texture = @This();

/// A texture image loaded into GPU memory.
width: u32,
height: u32,
handle: Handle,
/// Raw pixel data kept alive for platforms that need it beyond create_texture.
data: []u8,

/// Loads a PNG image from the specified file path into GPU memory.
pub fn load(allocator: std.mem.Allocator, path: []const u8) !Texture {
    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const buffer = try file.readToEndAlloc(allocator, std.math.maxInt(u24));
    defer allocator.free(buffer);

    var img = try Image.load_png_ex(allocator, buffer, .rgba8);
    errdefer img.deinit(allocator);

    return Texture{
        .width = img.width,
        .height = img.height,
        .data = img.data,
        .handle = try gfx.api.tab.create_texture(gfx.api.ptr, img.width, img.height, img.data),
    };
}

pub fn deinit(self: *Texture, allocator: std.mem.Allocator) void {
    allocator.free(self.data);
}

/// Binds the texture for rendering.
pub fn bind(self: *const Texture) void {
    gfx.api.tab.bind_texture(gfx.api.ptr, self.handle);
}
