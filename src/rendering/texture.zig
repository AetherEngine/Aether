const std = @import("std");
const builtin = @import("builtin");
const Image = @import("../util/image.zig");
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;
const options = @import("options");
const psp_gfx = if (builtin.os.tag == .psp) @import("../platform/psp/psp_gfx_ge.zig") else struct {};

pub const Handle = u32;

const Texture = @This();

width: u32,
height: u32,
handle: Handle,
/// Decoded pixel data kept alive in the render pool for platforms that need
/// CPU-side pixel data beyond the initial GPU upload.
data: []align(16) u8,

/// Creates a texture from raw RGBA pixel data.
/// The data is copied into the render pool.
pub fn load_from_data(width: u32, height: u32, pixels: []const u8) !Texture {
    const size = @as(usize, width) * height * tex_bpp;
    const source_size = @as(usize, width) * height * 4;
    if (pixels.len < source_size) return error.InsufficientData;

    const data = try Util.allocator(.render).alignedAlloc(u8, .fromByteUnits(16), size);
    errdefer Util.allocator(.render).free(data);
    if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565) {
        for (0..@as(usize, width) * height) |i| {
            const pixel = rgba_to_4444(pixels[i * 4 ..][0..4].*);
            data[i * 2] = @truncate(pixel);
            data[i * 2 + 1] = @truncate(pixel >> 8);
        }
    } else {
        @memcpy(data, pixels[0..size]);
    }

    return Texture{
        .width = width,
        .height = height,
        .data = data,
        .handle = try gfx.api.tab.create_texture(
            gfx.api.ptr,
            width,
            height,
            data,
        ),
    };
}

/// 4x4 solid white default texture, initialized by `init()`.
pub var Default: Texture = undefined;

pub fn init_defaults() !void {
    const pixels = comptime blk: {
        var data: [4 * 4 * 4]u8 = undefined;
        @memset(&data, 0xFF);
        break :blk data;
    };
    Default = try load_from_data(4, 4, &pixels);
}

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
    const color_mode: Image.ColorMode = if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565)
        .rgba4444
    else
        .rgba8;

    const img = try Image.load_png_ex(
        Util.allocator(.render),
        Util.allocator(.render),
        reader,
        color_mode,
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

/// Returns the RGBA pixel at (x, y), accounting for swizzled layout and
/// pixel format on PSP.
pub fn get_pixel(self: *const Texture, x: u32, y: u32) [4]u8 {
    const offset = pixel_offset(self, x, y);
    if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565) {
        const lo: u16 = self.data[offset];
        const hi: u16 = self.data[offset + 1];
        const pixel = lo | (hi << 8);
        return .{
            @truncate((pixel & 0x000F) << 4 | (pixel & 0x000F)),
            @truncate((pixel & 0x00F0) | (pixel >> 4 & 0x000F)),
            @truncate((pixel >> 4 & 0x00F0) | (pixel >> 8 & 0x000F)),
            @truncate((pixel >> 8 & 0x00F0) | (pixel >> 12)),
        };
    }
    return self.data[offset..][0..4].*;
}

/// Sets the RGBA pixel at (x, y), accounting for swizzled layout and
/// pixel format on PSP. Call `update()` after all modifications to push
/// changes to the GPU.
pub fn set_pixel(self: *Texture, x: u32, y: u32, rgba: [4]u8) void {
    const offset = pixel_offset(self, x, y);
    if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565) {
        const pixel = rgba_to_4444(rgba);
        self.data[offset] = @truncate(pixel);
        self.data[offset + 1] = @truncate(pixel >> 8);
        return;
    }
    self.data[offset..][0..4].* = rgba;
}

const tex_bpp: u32 = if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565) 2 else 4;

fn rgba_to_4444(rgba: [4]u8) u16 {
    const r: u16 = rgba[0] >> 4;
    const g: u16 = rgba[1] >> 4;
    const b: u16 = rgba[2] >> 4;
    const a: u16 = rgba[3] >> 4;
    return (a << 12) | (b << 8) | (g << 4) | r;
}

fn pixel_offset(self: *const Texture, x: u32, y: u32) usize {
    if (builtin.os.tag == .psp) {
        const width_bytes = self.width * tex_bpp;
        if (width_bytes * self.height >= 8 * 1024) {
            return psp_gfx.swizzled_offset(x, y, self.width);
        }
    }
    return (@as(usize, y) * self.width + x) * tex_bpp;
}

/// Binds the texture for the next draw call.
pub fn bind(self: *const Texture) void {
    gfx.api.tab.bind_texture(gfx.api.ptr, self.handle);
}
