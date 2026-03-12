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
pub fn load(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Texture {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var temp: [4096]u8 = undefined;
    var reader = file.reader(io, &temp);

    const len = try reader.getSize();

    const buffer = try allocator.alloc(u8, len);
    defer allocator.free(buffer);

    try reader.interface.readSliceAll(buffer);
    return load_memory(allocator, buffer);
}

/// Loads a PNG image from in-memory bytes into GPU memory.
pub fn load_memory(allocator: std.mem.Allocator, png_bytes: []const u8) !Texture {
    var img = try Image.load_png_ex(allocator, png_bytes, .rgba8);
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
