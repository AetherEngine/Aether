const std = @import("std");
const builtin = @import("builtin");
const Image = @import("../util/image.zig");
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;
const psp_gfx = if (builtin.os.tag == .psp) @import("../platform/psp/psp_gfx.zig") else struct {};

pub const Handle = u32;

const Texture = @This();

width: u32,
height: u32,
handle: Handle,
/// Decoded pixel data kept alive in the render pool for platforms that need
/// CPU-side pixel data beyond the initial GPU upload.
data: []align(16) u8,

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

/// Pushes the current contents of `data` to the GPU.
/// Modify `data` directly, then call `update()` to apply the changes.
pub fn update(self: *const Texture) void {
    gfx.api.tab.update_texture(gfx.api.ptr, self.handle, self.data);
}

/// Forces the texture into fast GPU-resident memory (e.g. VRAM on PSP).
/// No-op on platforms where textures are already GPU-resident (OpenGL, Vulkan).
pub fn force_resident(self: *const Texture) void {
    gfx.api.tab.force_texture_resident(gfx.api.ptr, self.handle);
}

/// Returns the RGBA pixel at (x, y), accounting for swizzled layout on PSP.
pub fn get_pixel(self: *const Texture, x: u32, y: u32) [4]u8 {
    const offset = pixel_offset(self, x, y);
    return self.data[offset..][0..4].*;
}

/// Sets the RGBA pixel at (x, y), accounting for swizzled layout on PSP.
/// Call `update()` after all modifications to push changes to the GPU.
pub fn set_pixel(self: *Texture, x: u32, y: u32, rgba: [4]u8) void {
    const offset = pixel_offset(self, x, y);
    self.data[offset..][0..4].* = rgba;
}

fn pixel_offset(self: *const Texture, x: u32, y: u32) usize {
    if (builtin.os.tag == .psp) {
        const width_bytes = self.width * 4;
        if (width_bytes * self.height >= 8 * 1024) {
            return psp_gfx.swizzled_offset(x, y, self.width);
        }
    }
    return (@as(usize, y) * self.width + x) * 4;
}

/// Binds the texture for the next draw call.
pub fn bind(self: *const Texture) void {
    gfx.api.tab.bind_texture(gfx.api.ptr, self.handle);
}
