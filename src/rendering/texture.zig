const std = @import("std");
const Image = @import("../util/image.zig");
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;

const Texture = @This();

width: u32,
height: u32,
handle: Handle,
/// Decoded pixel data kept alive in the render pool for platforms that need
/// CPU-side pixel data beyond the initial GPU upload.
data: []u8,

/// Loads a PNG from `path` into GPU memory.
/// The decoded pixel buffer lives in the render pool.
pub fn load(path: []const u8) !Texture {
    const io = Util.io();

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var temp: [4096]u8 = undefined;
    var reader = file.reader(io, &temp);

    return load_from_reader(&reader.interface);
}

/// Loads a PNG from any reader into GPU memory.
/// Intermediate decode buffers use the scratch pool; the final pixel data
/// uses the render pool.
pub fn load_from_reader(reader: *std.Io.Reader) !Texture {
    const img = try Image.load_png_ex(
        Util.allocator(.scratch),
        Util.allocator(.render),
        reader,
        .rgba8,
    );
    errdefer Util.allocator(.render).free(img.data);

    return Texture{
        .width = img.width,
        .height = img.height,
        .data = img.data,
        .handle = try gfx.api.tab.create_texture(
            gfx.api.ptr,
            img.width,
            img.height,
            img.data,
        ),
    };
}

/// Frees GPU resources and the render-pool pixel buffer.
pub fn deinit(self: *Texture) void {
    gfx.api.tab.destroy_texture(gfx.api.ptr, self.handle);
    Util.allocator(.render).free(self.data);
}

/// Forces the texture into fast GPU-resident memory (e.g. VRAM on PSP).
/// No-op on platforms where textures are already GPU-resident (OpenGL, Vulkan).
pub fn force_resident(self: *const Texture) void {
    gfx.api.tab.force_texture_resident(gfx.api.ptr, self.handle);
}

/// Binds the texture for the next draw call.
pub fn bind(self: *const Texture) void {
    gfx.api.tab.bind_texture(gfx.api.ptr, self.handle);
}
