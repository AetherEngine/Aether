const std = @import("std");
const Image = @import("../util/image.zig");
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;

const Texture = @This();

width:  u32,
height: u32,
handle: Handle,
/// Decoded pixel data kept alive in the render pool for platforms that need
/// CPU-side pixel data beyond the initial GPU upload.
data: []u8,

/// Loads a PNG from `path` into GPU memory.
/// File bytes are read into the scratch pool and freed after decode.
/// The decoded pixel buffer lives in the render pool.
pub fn load(io: std.Io, path: []const u8) !Texture {
    const scratch = Util.allocator(.scratch);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var temp: [4096]u8 = undefined;
    var reader = file.reader(io, &temp);

    const len = try reader.getSize();
    const buffer = try scratch.alloc(u8, len);
    defer scratch.free(buffer);

    try reader.interface.readSliceAll(buffer);
    return load_memory(buffer);
}

/// Loads a PNG from in-memory bytes into GPU memory.
/// Intermediate decode buffers use the scratch pool; the final pixel data
/// uses the render pool.
pub fn load_memory(png_bytes: []const u8) !Texture {
    var img = try Image.load_png_ex(
        Util.allocator(.scratch),
        Util.allocator(.render),
        png_bytes,
        .rgba8,
    );
    errdefer Util.allocator(.render).free(img.data);

    return Texture{
        .width  = img.width,
        .height = img.height,
        .data   = img.data,
        .handle = try gfx.api.tab.create_texture(
            gfx.api.ptr, img.width, img.height, img.data,
        ),
    };
}

/// Frees GPU resources and the render-pool pixel buffer.
pub fn deinit(self: *Texture) void {
    gfx.api.tab.destroy_texture(gfx.api.ptr, self.handle);
    Util.allocator(.render).free(self.data);
}

/// Binds the texture for the next draw call.
pub fn bind(self: *const Texture) void {
    gfx.api.tab.bind_texture(gfx.api.ptr, self.handle);
}
