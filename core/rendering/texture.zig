const std = @import("std");
const Image = @import("../util/image.zig");
const Platform = @import("platform");
const gfx = Platform.gfx;
const native_pixels = gfx.texture_pixels;

const texture = @import("platform").graphics.texture;
pub const TextureHandleTag = texture.TextureHandleTag;
pub const Handle = texture.Handle;

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

pub const Residency = texture.Residency;

pub const Error = error{
    InsufficientData,
    CpuReadAccessDenied,
    CpuWriteAccessDenied,
    NoCpuPixels,
    PixelOutOfBounds,
};

pub const CreateError = Error ||
    std.mem.Allocator.Error ||
    @import("platform").gfx_api.CreateTextureError;

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

pub const UploadDesc = texture.UploadDesc;

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

pub const RegionError = Error || Image.RegionError;

/// Copies a linear image region into native CPU storage, converting pixel
/// format/layout as needed. Call update() once after all edits; uploads still
/// transfer the entire texture. Source and texture backing must not overlap.
pub fn copy_image_region(self: *Texture, source: Image.View, region: Image.Region, x: u32, y: u32) RegionError!void {
    try source.validate();
    try region.validate(source.width, source.height);
    try (Image.Region{ .x = x, .y = y, .width = region.width, .height = region.height }).validate(self.width, self.height);
    const data = try self.mutable_cpu_pixels();
    try self.validate_backing(data);
    if (@intFromPtr(data.ptr) < @intFromPtr(source.data.ptr) + source.data.len and
        @intFromPtr(source.data.ptr) < @intFromPtr(data.ptr) + data.len) return error.AliasedImages;
    try self.validate_region_offsets(data.len, .{ .x = x, .y = y, .width = region.width, .height = region.height });
    for (0..region.height) |row| for (0..region.width) |column| {
        const ix: u32 = @intCast(column);
        const iy: u32 = @intCast(row);
        const rgba = source.read_pixel(region.x + ix, region.y + iy);
        native_pixels.write(data, native_pixels.offset(self.width, self.height, x + ix, y + iy), rgba);
    };
}

/// Native CPU texture-to-texture copy. In-place overlapping moves are safe;
/// read and write permissions are checked before any pixels change.
pub fn copy_region(self: *Texture, source: *const Texture, region: Image.Region, x: u32, y: u32) RegionError!void {
    try region.validate(source.width, source.height);
    try (Image.Region{ .x = x, .y = y, .width = region.width, .height = region.height }).validate(self.width, self.height);
    const src = try source.cpu_pixels();
    const dst = try self.mutable_cpu_pixels();
    try self.validate_backing(dst);
    try source.validate_backing(src);
    const same_image = src.ptr == dst.ptr and source.width == self.width and source.height == self.height;
    const overlap = @intFromPtr(dst.ptr) < @intFromPtr(src.ptr) + src.len and @intFromPtr(src.ptr) < @intFromPtr(dst.ptr) + dst.len;
    if (overlap and !same_image) return error.AliasedImages;
    try source.validate_region_offsets(src.len, region);
    try self.validate_region_offsets(dst.len, .{ .x = x, .y = y, .width = region.width, .height = region.height });
    for (0..region.height) |row| for (0..region.width) |column| {
        const ix: u32 = @intCast(if (same_image and x > region.x) region.width - 1 - column else column);
        const iy: u32 = @intCast(if (same_image and y > region.y) region.height - 1 - row else row);
        const rgba = native_pixels.read(src, native_pixels.offset(source.width, source.height, region.x + ix, region.y + iy));
        native_pixels.write(dst, native_pixels.offset(self.width, self.height, x + ix, y + iy), rgba);
    };
}

fn validate_backing(self: *const Texture, data: []const u8) Image.RegionError!void {
    const pixels = @as(u64, self.width) * self.height;
    // Native offset calculations use u32; reject dimensions that overflow it.
    if (self.width == 0 or self.height == 0 or pixels > std.math.maxInt(u32) / native_pixels.bytes_per_pixel) return error.InvalidDimensions;
    const size = pixels * native_pixels.bytes_per_pixel;
    if (data.len < size) return error.InsufficientData;
}

fn validate_region_offsets(self: *const Texture, len: usize, region: Image.Region) Image.RegionError!void {
    for (0..region.height) |row| for (0..region.width) |column| {
        const offset = native_pixels.offset(self.width, self.height, region.x + @as(u32, @intCast(column)), region.y + @as(u32, @intCast(row)));
        if (offset > len or native_pixels.bytes_per_pixel > len - offset) return error.InsufficientData;
    };
}

test "texture region copy converts images and moves overlapping CPU pixels" {
    var pixels: [4 * 4 * native_pixels.bytes_per_pixel]u8 align(16) = @splat(0);
    var texture_value: Texture = .{
        .width = 4,
        .height = 4,
        .handle = .{},
        .cpu_access = .read_write,
        .residency = .backend_default,
        .backing = &pixels,
    };
    const source: Image.View = .{ .width = 2, .height = 1, .mode = .rgba4444, .data = &.{ 0x0f, 0xf0, 0xf0, 0xf0 } };
    try texture_value.copy_image_region(source, .{ .width = 2, .height = 1 }, 0, 0);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, try texture_value.get_pixel(0, 0));
    try texture_value.copy_region(&texture_value, .{ .width = 2, .height = 1 }, 1, 0);
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, try texture_value.get_pixel(1, 0));
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, try texture_value.get_pixel(2, 0));
    const before = pixels;
    try std.testing.expectError(error.RegionOutOfBounds, texture_value.copy_image_region(source, .{ .width = 2, .height = 1 }, 3, 0));
    try std.testing.expectEqual(before, pixels);
    texture_value.cpu_access = .read;
    try std.testing.expectError(error.CpuWriteAccessDenied, texture_value.copy_image_region(source, .{ .width = 2, .height = 1 }, 0, 0));
}
