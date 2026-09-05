const std = @import("std");
const Image = @import("../util/image.zig");
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;
const native_pixels = gfx.texture_pixels;

pub const TextureHandleTag = enum {};
pub const Handle = Util.HandleType(TextureHandleTag);

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
    PixelOutOfBounds,
};

pub const CreateError = Error ||
    std.mem.Allocator.Error ||
    @import("../platform/gfx_api.zig").CreateTextureError;

pub const LoadError = CreateError ||
    std.Io.Reader.Error ||
    std.Io.File.OpenError ||
    Image.Error;

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
/// Backend-native format and layout; retained even when `cpu_access` is none.
backing: ?[]align(16) u8,

/// Copies RGBA8 pixels into storage owned by `alloc`.
pub fn init(alloc: std.mem.Allocator, desc: *const Desc) CreateError!Texture {
    return load_from_data(alloc, desc.width, desc.height, desc.pixels, &.{
        .cpu_access = desc.cpu_access,
        .residency = desc.residency,
    });
}

pub fn load_from_data(alloc: std.mem.Allocator, width: u32, height: u32, source_pixels: []const u8, desc: *const LoadDesc) CreateError!Texture {
    const size = @as(usize, width) * height * native_pixels.bytes_per_pixel;
    const source_size = @as(usize, width) * height * 4;
    if (source_pixels.len < source_size) return error.InsufficientData;

    const backing = try alloc.alignedAlloc(u8, .fromByteUnits(16), size);
    errdefer alloc.free(backing);
    native_pixels.copy_from_rgba(backing, source_pixels);

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

pub fn init_defaults(alloc: std.mem.Allocator) CreateError!void {
    const default_pixels: [8 * 8 * 4]u8 = @splat(0xFF);
    Default = try load_from_data(alloc, 8, 8, &default_pixels, &.{ .cpu_access = .none });
}

/// Loads a PNG relative to `dir`, typically `engine.dirs.resources` or `.data`.
pub fn load(io: std.Io, dir: anytype, alloc: std.mem.Allocator, path: []const u8, desc: *const LoadDesc) LoadError!Texture {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var temp: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &temp);

    return load_from_reader(alloc, &reader.interface, desc);
}

/// Loads a PNG with pixel storage owned by `alloc`.
pub fn load_from_reader(alloc: std.mem.Allocator, reader: *std.Io.Reader, desc: *const LoadDesc) LoadError!Texture {
    const img = try Image.load_png_ex(alloc, alloc, reader, native_pixels.color_mode);
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

pub fn deinit(self: *Texture, alloc: std.mem.Allocator) void {
    defer self.* = undefined;

    gfx.api.destroy_texture(self.handle);
    if (self.backing) |data| alloc.free(data);
}

/// Uploads changes made through `set_pixel` or `mutable_cpu_pixels`.
pub fn update(self: *const Texture) Error!void {
    if (!self.cpu_access.can_write()) return error.CpuWriteAccessDenied;
    const data = self.backing orelse return error.NoCpuPixels;
    gfx.api.update_texture(self.handle, data);
}

/// Promotes backing storage to GPU memory where supported.
pub fn force_resident(self: *const Texture) void {
    gfx.api.force_texture_resident(self.handle);
}

/// Exposes native pixel storage. Use `get_pixel` for portable RGBA8 access.
pub fn cpu_pixels(self: *const Texture) Error![]const u8 {
    if (!self.cpu_access.can_read()) return error.CpuReadAccessDenied;
    return self.backing orelse error.NoCpuPixels;
}

/// Exposes writable native storage. Use `set_pixel` for portable RGBA8 writes.
pub fn mutable_cpu_pixels(self: *Texture) Error![]align(16) u8 {
    if (!self.cpu_access.can_write()) return error.CpuWriteAccessDenied;
    return self.backing orelse error.NoCpuPixels;
}

/// Reads RGBA8 regardless of the backend's storage format.
pub fn get_pixel(self: *const Texture, x: u32, y: u32) Error![4]u8 {
    if (x >= self.width or y >= self.height) return error.PixelOutOfBounds;
    const data = try self.cpu_pixels();
    return native_pixels.read(data, native_pixels.offset(self.width, self.height, x, y));
}

/// Writes RGBA8 into backend storage. Call `update` after all modifications.
pub fn set_pixel(self: *Texture, x: u32, y: u32, rgba: [4]u8) Error!void {
    if (x >= self.width or y >= self.height) return error.PixelOutOfBounds;
    const data = try self.mutable_cpu_pixels();
    native_pixels.write(data, native_pixels.offset(self.width, self.height, x, y), rgba);
}
