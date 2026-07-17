const std = @import("std");
const builtin = @import("builtin");
const Image = @import("../util/image.zig");
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;
const options = @import("options");
const psp_gfx = if (builtin.os.tag == .psp) @import("../platform/psp/psp_gfx_ge.zig") else struct {};
const use_streaming_file_reader = options.config.platform == .nintendo_switch;

pub const TextureHandleTag = enum {};
pub const Handle = Util.Handle(TextureHandleTag);

const Texture = @This();

pub const CpuAccess = enum {
    none,
    read,
    write,
    read_write,

    pub fn can_read(self: CpuAccess) bool {
        return self == .read or self == .read_write;
    }

    pub fn can_write(self: CpuAccess) bool {
        return self == .write or self == .read_write;
    }
};

pub const Residency = enum {
    backend_default,
    system_ram,
    prefer_vram,
};

pub const Error = error{
    InsufficientData,
    CpuReadAccessDenied,
    CpuWriteAccessDenied,
    NoCpuPixels,
};

pub const Desc = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
    cpu_access: CpuAccess = .none,
    residency: Residency = .backend_default,
};

pub const LoadDesc = struct {
    cpu_access: CpuAccess = .none,
    residency: Residency = .backend_default,
};

pub const UploadDesc = struct {
    width: u32,
    height: u32,
    pixels: []align(16) u8,
    residency: Residency = .backend_default,
};

width: u32,
height: u32,
handle: Handle,
cpu_access: CpuAccess,
residency: Residency,
/// Backend-facing pixel backing. Public CPU access is controlled by
/// `cpu_access`; some backends still require this RAM even when access is none.
backing: ?[]align(16) u8,

/// Creates a texture from raw RGBA pixel data.
/// The data is copied into the provided allocator.
pub fn init(alloc: std.mem.Allocator, desc: *const Desc) !Texture {
    return load_from_data(alloc, desc.width, desc.height, desc.pixels, .{
        .cpu_access = desc.cpu_access,
        .residency = desc.residency,
    });
}

pub fn load_from_data(alloc: std.mem.Allocator, width: u32, height: u32, source_pixels: []const u8, desc: LoadDesc) !Texture {
    const size = @as(usize, width) * height * tex_bpp;
    const source_size = @as(usize, width) * height * 4;
    if (source_pixels.len < source_size) return error.InsufficientData;

    const backing = try alloc.alignedAlloc(u8, .fromByteUnits(16), size);
    errdefer alloc.free(backing);
    if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565) {
        for (0..@as(usize, width) * height) |i| {
            const pixel = rgba_to_4444(source_pixels[i * 4 ..][0..4].*);
            backing[i * 2] = @truncate(pixel);
            backing[i * 2 + 1] = @truncate(pixel >> 8);
        }
    } else {
        @memcpy(backing, source_pixels[0..size]);
    }

    return Texture{
        .width = width,
        .height = height,
        .cpu_access = desc.cpu_access,
        .residency = desc.residency,
        .backing = backing,
        .handle = try gfx.api.create_texture(&.{
            .width = width,
            .height = height,
            .pixels = backing,
            .residency = desc.residency,
        }),
    };
}

/// 8x8 solid white default texture, initialized by `init_defaults`.
pub var Default: Texture = undefined;

pub fn init_defaults(alloc: std.mem.Allocator) !void {
    const default_pixels = comptime blk: {
        var data: [8 * 8 * 4]u8 = undefined;
        @memset(&data, 0xFF);
        break :blk data;
    };
    Default = try load_from_data(alloc, 8, 8, &default_pixels, .{ .cpu_access = .none });
}

/// Loads a PNG from `path` (resolved against `dir`) into GPU memory.
/// The decoded pixel buffer lives in the provided allocator.
///
/// Callers pass `engine.dirs.resources` for bundled textures or
/// `engine.dirs.data` for user-provided ones. Do not use
/// `std.Io.Dir.cwd()` -- CWD is not guaranteed to be the app root
/// (Finder-launched `.app` bundles give CWD = `/`).
pub fn load(io: std.Io, dir: anytype, alloc: std.mem.Allocator, path: []const u8, desc: LoadDesc) !Texture {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var temp: [4096]u8 = undefined;
    var reader = if (use_streaming_file_reader)
        file.readerStreaming(io, &temp)
    else
        file.reader(io, &temp);

    return load_from_reader(alloc, &reader.interface, desc);
}

/// Loads a PNG from any reader into GPU memory.
/// The final pixel data uses the provided allocator.
pub fn load_from_reader(alloc: std.mem.Allocator, reader: *std.Io.Reader, desc: LoadDesc) !Texture {
    const color_mode: Image.ColorMode = if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565)
        .rgba4444
    else
        .rgba8;

    const img = try Image.load_png_ex(
        alloc,
        alloc,
        reader,
        color_mode,
    );
    errdefer alloc.free(img.data);

    return Texture{
        .width = img.width,
        .height = img.height,
        .cpu_access = desc.cpu_access,
        .residency = desc.residency,
        .backing = img.data,
        .handle = try gfx.api.create_texture(&.{
            .width = img.width,
            .height = img.height,
            .pixels = img.data,
            .residency = desc.residency,
        }),
    };
}

/// Frees GPU resources and the pixel buffer.
pub fn deinit(self: *Texture, alloc: std.mem.Allocator) void {
    gfx.api.destroy_texture(self.handle);
    if (self.backing) |data| alloc.free(data);
    self.backing = null;
    self.handle = .none;
}

/// Pushes the current contents of `data` to the GPU.
/// Modify `data` directly, then call `update()` to apply the changes.
pub fn update(self: *const Texture) Error!void {
    if (!self.cpu_access.can_write()) return error.CpuWriteAccessDenied;
    const data = self.backing orelse return error.NoCpuPixels;
    gfx.api.update_texture(self.handle, data);
}

/// Forces the texture into fast GPU-resident memory (e.g. VRAM on PSP).
/// No-op on platforms where textures are already GPU-resident (OpenGL, Vulkan).
pub fn force_resident(self: *const Texture) void {
    gfx.api.force_texture_resident(self.handle);
}

pub fn cpu_pixels(self: *const Texture) Error![]const u8 {
    if (!self.cpu_access.can_read()) return error.CpuReadAccessDenied;
    return self.backing orelse error.NoCpuPixels;
}

pub fn mutable_cpu_pixels(self: *Texture) Error![]align(16) u8 {
    if (!self.cpu_access.can_write()) return error.CpuWriteAccessDenied;
    return self.backing orelse error.NoCpuPixels;
}

/// Returns the RGBA pixel at (x, y), accounting for swizzled layout and
/// pixel format on PSP.
pub fn get_pixel(self: *const Texture, x: u32, y: u32) Error![4]u8 {
    const data = try self.cpu_pixels();
    const offset = pixel_offset(self, x, y);
    if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565) {
        const lo: u16 = data[offset];
        const hi: u16 = data[offset + 1];
        const pixel = lo | (hi << 8);
        return .{
            @truncate((pixel & 0x000F) << 4 | (pixel & 0x000F)),
            @truncate((pixel & 0x00F0) | (pixel >> 4 & 0x000F)),
            @truncate((pixel >> 4 & 0x00F0) | (pixel >> 8 & 0x000F)),
            @truncate((pixel >> 8 & 0x00F0) | (pixel >> 12)),
        };
    }
    return data[offset..][0..4].*;
}

/// Sets the RGBA pixel at (x, y), accounting for swizzled layout and
/// pixel format on PSP. Call `update()` after all modifications to push
/// changes to the GPU.
pub fn set_pixel(self: *Texture, x: u32, y: u32, rgba: [4]u8) Error!void {
    const data = try self.mutable_cpu_pixels();
    const offset = pixel_offset(self, x, y);
    if (builtin.os.tag == .psp and options.config.psp_display_mode == .rgb565) {
        const pixel = rgba_to_4444(rgba);
        data[offset] = @truncate(pixel);
        data[offset + 1] = @truncate(pixel >> 8);
        return;
    }
    data[offset..][0..4].* = rgba;
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
