const std = @import("std");
const flate = std.compress.flate;

pub const ColorMode = @import("platform").graphics.PixelFormat;

pub const Image = struct {
    width: u32,
    height: u32,
    data: []align(16) u8,
    mode: ColorMode,

    pub fn view(self: *const Image) View {
        return .{ .width = self.width, .height = self.height, .data = self.data, .mode = self.mode };
    }

    pub fn mutable_view(self: *Image) MutableView {
        return .{ .width = self.width, .height = self.height, .data = self.data, .mode = self.mode };
    }

    pub fn copy_region(self: *Image, source: View, region: Region, x: u32, y: u32) RegionError!void {
        return self.mutable_view().copy_region(source, region, x, y);
    }

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        defer self.* = undefined;

        allocator.free(self.data);
    }
};

pub const RegionError = error{ InvalidDimensions, InsufficientData, RegionOutOfBounds, FormatMismatch, AliasedImages };

pub const Region = struct {
    x: u32 = 0,
    y: u32 = 0,
    width: u32,
    height: u32,

    pub fn validate(self: Region, width: u32, height: u32) RegionError!void {
        if (self.x > width or self.y > height or self.width > width - self.x or self.height > height - self.y)
            return error.RegionOutOfBounds;
    }
};

pub fn bytes_per_pixel(mode: ColorMode) usize {
    return if (mode == .rgba8) 4 else 2;
}

/// Borrowed, tightly packed, row-major pixels. Unlike Texture backing storage,
/// this layout is always linear, including on targets with swizzled textures.
pub const View = struct {
    width: u32,
    height: u32,
    data: []const u8,
    mode: ColorMode = .rgba8,

    pub fn validate(self: View) RegionError!void {
        if (self.width == 0 or self.height == 0) return error.InvalidDimensions;
        const pixels = std.math.mul(usize, self.width, self.height) catch return error.InvalidDimensions;
        const size = std.math.mul(usize, pixels, bytes_per_pixel(self.mode)) catch return error.InvalidDimensions;
        if (self.data.len < size) return error.InsufficientData;
    }

    pub fn get_pixel(self: View, x: u32, y: u32) RegionError![4]u8 {
        try self.validate();
        try (Region{ .x = x, .y = y, .width = 1, .height = 1 }).validate(self.width, self.height);
        return self.read_pixel(x, y);
    }

    /// Requires validate() and in-bounds coordinates; useful in validated loops.
    pub fn read_pixel(self: View, x: u32, y: u32) [4]u8 {
        const offset = (@as(usize, y) * self.width + x) * bytes_per_pixel(self.mode);
        if (self.mode == .rgba8) return self.data[offset..][0..4].*;
        const value = std.mem.readInt(u16, self.data[offset..][0..2], .little);
        return switch (self.mode) {
            .rgba5551 => .{
                expand5(@intCast(value >> 11)),
                expand5(@intCast((value >> 6) & 31)),
                expand5(@intCast((value >> 1) & 31)),
                if (value & 1 != 0) 255 else 0,
            },
            .rgba4444 => .{
                @as(u8, @intCast(value & 15)) * 17,
                @as(u8, @intCast((value >> 4) & 15)) * 17,
                @as(u8, @intCast((value >> 8) & 15)) * 17,
                @as(u8, @intCast(value >> 12)) * 17,
            },
            .rgba8 => unreachable,
        };
    }

    fn expand5(v: u8) u8 {
        return (v << 3) | (v >> 2);
    }
};

pub const MutableView = struct {
    width: u32,
    height: u32,
    data: []u8,
    mode: ColorMode = .rgba8,

    pub fn view(self: MutableView) View {
        return .{ .width = self.width, .height = self.height, .data = self.data, .mode = self.mode };
    }

    /// Copies equal-format pixels without allocation. In-place moves are safe.
    /// Distinct views with overlapping backing storage are rejected. Validation
    /// completes before any pixels change; empty regions are valid no-ops.
    pub fn copy_region(self: MutableView, source: View, region: Region, x: u32, y: u32) RegionError!void {
        try self.view().validate();
        try source.validate();
        try region.validate(source.width, source.height);
        try (Region{ .x = x, .y = y, .width = region.width, .height = region.height }).validate(self.width, self.height);
        if (self.mode != source.mode) return error.FormatMismatch;
        if (region.width == 0 or region.height == 0) return;
        const same_image = self.data.ptr == source.data.ptr and self.width == source.width and self.height == source.height;
        const overlap = @intFromPtr(self.data.ptr) < @intFromPtr(source.data.ptr) + source.data.len and
            @intFromPtr(source.data.ptr) < @intFromPtr(self.data.ptr) + self.data.len;
        if (overlap and !same_image) return error.AliasedImages;
        const bpp = bytes_per_pixel(self.mode);
        const row_size = @as(usize, region.width) * bpp;
        for (0..region.height) |i| {
            const row = if (same_image and y > region.y) region.height - 1 - i else i;
            const dst_offset = ((@as(usize, y) + row) * self.width + x) * bpp;
            const src_offset = ((@as(usize, region.y) + row) * source.width + region.x) * bpp;
            const dst = self.data[dst_offset..][0..row_size];
            const src = source.data[src_offset..][0..row_size];
            if (same_image and dst_offset > src_offset) std.mem.copyBackwards(u8, dst, src) else std.mem.copyForwards(u8, dst, src);
        }
    }
};

pub const Error = error{
    InvalidPNG,
    UnsupportedInterlacing,
    UnsupportedColorType,
    InvalidFilter,
    WriteFailed,
} ||
    std.mem.Allocator.Error ||
    std.Io.Reader.Error ||
    flate.Decompress.Error;

const png_signature = "\x89PNG\r\n\x1a\n";

/// Decode PNG from a reader -> RGBA8. Caller owns returned slice.
pub fn load_png(allocator: std.mem.Allocator, reader: *std.Io.Reader) Error![]u8 {
    const img = try load_png_ex(allocator, allocator, reader, .rgba8);
    return img.data;
}

/// Decode PNG from a reader with explicit color mode. Caller owns image.data.
/// `scratch` is used for all temporary allocations during decoding.
/// `render` is used for the final pixel buffer stored in `image.data`.
pub fn load_png_ex(scratch: std.mem.Allocator, render: std.mem.Allocator, reader: *std.Io.Reader, mode: ColorMode) Error!Image {
    var sig_buf: [8]u8 = undefined;
    try reader.readSliceAll(&sig_buf);
    if (!std.mem.eql(u8, &sig_buf, png_signature)) return error.InvalidPNG;

    var width: u32 = 0;
    var height: u32 = 0;
    var bit_depth: u8 = 0;
    var color_type: u8 = 0;
    var ihdr_found = false;

    var palette: [256][3]u8 = undefined;
    var palette_len: u32 = 0;
    var trns_alpha: [256]u8 = @splat(255);
    var trns_len: u32 = 0;
    var trns_gray: u16 = 0;
    var trns_rgb: [3]u16 = .{ 0, 0, 0 };
    var has_trns = false;

    var idat_buf: std.ArrayList(u8) = .empty;
    defer idat_buf.deinit(scratch);

    while (true) {
        var chunk_header: [8]u8 = undefined;
        reader.readSliceAll(&chunk_header) catch break;
        const length = std.mem.readInt(u32, chunk_header[0..4], .big);
        const chunk_type = chunk_header[4..8];

        if (std.mem.eql(u8, chunk_type, "IHDR")) {
            if (length < 13) return error.InvalidPNG;
            var ihdr: [13]u8 = undefined;
            try reader.readSliceAll(&ihdr);
            width = std.mem.readInt(u32, ihdr[0..4], .big);
            height = std.mem.readInt(u32, ihdr[4..8], .big);
            bit_depth = ihdr[8];
            color_type = ihdr[9];
            const compression_method = ihdr[10];
            const filter_method = ihdr[11];
            const interlace_method = ihdr[12];
            if (interlace_method != 0) return error.UnsupportedInterlacing;
            if (compression_method != 0 or filter_method != 0) return error.InvalidPNG;
            switch (color_type) {
                0, 2, 4, 6 => switch (bit_depth) {
                    8, 16 => {},
                    else => return error.UnsupportedColorType,
                },
                3 => switch (bit_depth) {
                    1, 2, 4, 8 => {},
                    else => return error.UnsupportedColorType,
                },
                else => return error.UnsupportedColorType,
            }
            ihdr_found = true;
            try reader.discardAll(length - 13 + 4);
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            const chunk_data = try scratch.alloc(u8, length);
            defer scratch.free(chunk_data);

            try reader.readSliceAll(chunk_data);
            palette_len = @intCast(length / 3);
            for (0..palette_len) |i| {
                palette[i] = .{ chunk_data[i * 3], chunk_data[i * 3 + 1], chunk_data[i * 3 + 2] };
            }
            try reader.discardAll(4);
        } else if (std.mem.eql(u8, chunk_type, "tRNS")) {
            const chunk_data = try scratch.alloc(u8, length);
            defer scratch.free(chunk_data);

            try reader.readSliceAll(chunk_data);
            has_trns = true;
            switch (color_type) {
                0 => if (chunk_data.len >= 2) {
                    trns_gray = std.mem.readInt(u16, chunk_data[0..2], .big);
                },
                2 => if (chunk_data.len >= 6) {
                    trns_rgb[0] = std.mem.readInt(u16, chunk_data[0..2], .big);
                    trns_rgb[1] = std.mem.readInt(u16, chunk_data[2..4], .big);
                    trns_rgb[2] = std.mem.readInt(u16, chunk_data[4..6], .big);
                },
                3 => {
                    trns_len = @intCast(chunk_data.len);
                    for (0..trns_len) |i| trns_alpha[i] = chunk_data[i];
                },
                else => {},
            }
            try reader.discardAll(4);
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            const prev_len = idat_buf.items.len;
            try idat_buf.resize(scratch, prev_len + length);
            try reader.readSliceAll(idat_buf.items[prev_len..]);
            try reader.discardAll(4);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        } else {
            try reader.discardAll(length + 4);
        }
    }

    if (!ihdr_found) return error.InvalidPNG;
    if (width == 0 or height == 0) return error.InvalidPNG;

    const channels: u32 = switch (color_type) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => return error.UnsupportedColorType,
    };
    const bytes_per_sample: u32 = if (bit_depth == 16) 2 else 1;
    const raw_stride: u32 = if (color_type == 3 and bit_depth < 8)
        (width * bit_depth + 7) / 8
    else
        width * channels * bytes_per_sample;

    var in_reader: std.Io.Reader = .fixed(idat_buf.items);
    var aw: std.Io.Writer.Allocating = .init(scratch);
    defer aw.deinit();

    var decomp: flate.Decompress = .init(&in_reader, .zlib, &.{});
    _ = try decomp.reader.streamRemaining(&aw.writer);
    const raw = aw.written();

    const expected_raw_size: usize = @as(usize, height) * (1 + raw_stride);
    if (raw.len < expected_raw_size) return error.InvalidPNG;

    const bpp: u32 = @max(1, @as(u32, bit_depth) * channels / 8);

    const unfiltered = try scratch.alloc(u8, @as(usize, height) * raw_stride);
    defer scratch.free(unfiltered);

    var raw_pos: usize = 0;
    for (0..height) |y| {
        if (raw_pos >= raw.len) return error.InvalidPNG;
        const filter_byte = raw[raw_pos];
        raw_pos += 1;

        const dst = unfiltered[y * raw_stride .. (y + 1) * raw_stride];
        const prev: ?[]const u8 = if (y > 0) unfiltered[(y - 1) * raw_stride .. y * raw_stride] else null;

        if (raw_pos + raw_stride > raw.len) return error.InvalidPNG;
        @memcpy(dst, raw[raw_pos .. raw_pos + raw_stride]);
        raw_pos += raw_stride;

        switch (filter_byte) {
            0 => {}, // None
            1 => { // Sub: Recon(x) = Filt(x) + Recon(a)
                for (bpp..dst.len) |i| {
                    dst[i] +%= dst[i - bpp];
                }
            },
            2 => { // Up: Recon(x) = Filt(x) + Recon(b)
                if (prev) |p| {
                    for (0..dst.len) |i| {
                        dst[i] +%= p[i];
                    }
                }
            },
            3 => { // Average
                for (0..dst.len) |i| {
                    const left: u16 = if (i >= bpp) dst[i - bpp] else 0;
                    const up: u16 = if (prev) |p| p[i] else 0;
                    dst[i] +%= @truncate((left + up) / 2);
                }
            },
            4 => { // Paeth
                for (0..dst.len) |i| {
                    const a: u8 = if (i >= bpp) dst[i - bpp] else 0;
                    const b: u8 = if (prev) |p| p[i] else 0;
                    const c: u8 = if (prev != null and i >= bpp) prev.?[i - bpp] else 0;
                    dst[i] +%= paeth_predictor(a, b, c);
                }
            },
            else => return error.InvalidFilter,
        }
    }

    const pixel_count: usize = @as(usize, width) * height;
    const rgba8 = try render.alignedAlloc(u8, .fromByteUnits(16), pixel_count * 4);

    for (0..height) |y| {
        const row = unfiltered[y * raw_stride .. (y + 1) * raw_stride];
        for (0..@as(usize, width)) |x| {
            const d = (y * width + x) * 4;
            switch (color_type) {
                0 => { // Grayscale
                    if (bit_depth == 16) {
                        const gray16 = std.mem.readInt(u16, row[x * 2 ..][0..2], .big);
                        const v: u8 = @truncate(gray16 >> 8);
                        const alpha: u8 = if (has_trns and gray16 == trns_gray) 0 else 255;
                        rgba8[d] = v;
                        rgba8[d + 1] = v;
                        rgba8[d + 2] = v;
                        rgba8[d + 3] = alpha;
                    } else {
                        const v = row[x];
                        const alpha: u8 = if (has_trns and v == @as(u8, @truncate(trns_gray))) 0 else 255;
                        rgba8[d] = v;
                        rgba8[d + 1] = v;
                        rgba8[d + 2] = v;
                        rgba8[d + 3] = alpha;
                    }
                },
                2 => { // RGB
                    if (bit_depth == 16) {
                        const r16 = std.mem.readInt(u16, row[x * 6 ..][0..2], .big);
                        const g16 = std.mem.readInt(u16, row[x * 6 + 2 ..][0..2], .big);
                        const b16 = std.mem.readInt(u16, row[x * 6 + 4 ..][0..2], .big);
                        const alpha: u8 = if (has_trns and r16 == trns_rgb[0] and g16 == trns_rgb[1] and b16 == trns_rgb[2]) 0 else 255;
                        rgba8[d] = @truncate(r16 >> 8);
                        rgba8[d + 1] = @truncate(g16 >> 8);
                        rgba8[d + 2] = @truncate(b16 >> 8);
                        rgba8[d + 3] = alpha;
                    } else {
                        const r = row[x * 3];
                        const g = row[x * 3 + 1];
                        const b = row[x * 3 + 2];
                        const alpha: u8 = if (has_trns and
                            r == @as(u8, @truncate(trns_rgb[0])) and
                            g == @as(u8, @truncate(trns_rgb[1])) and
                            b == @as(u8, @truncate(trns_rgb[2]))) 0 else 255;
                        rgba8[d] = r;
                        rgba8[d + 1] = g;
                        rgba8[d + 2] = b;
                        rgba8[d + 3] = alpha;
                    }
                },
                3 => { // Indexed
                    const idx: u8 = if (bit_depth == 8) row[x] else blk: {
                        const bit_off: usize = x * bit_depth;
                        const byte_idx = bit_off / 8;
                        const bit_in_byte = bit_off % 8;
                        const shift: u3 = @intCast(8 - @as(usize, bit_depth) - bit_in_byte);
                        const mask: u8 = (@as(u8, 1) << @intCast(bit_depth)) - 1;
                        break :blk (row[byte_idx] >> shift) & mask;
                    };
                    rgba8[d] = palette[idx][0];
                    rgba8[d + 1] = palette[idx][1];
                    rgba8[d + 2] = palette[idx][2];
                    rgba8[d + 3] = if (idx < trns_len) trns_alpha[idx] else 255;
                },
                4 => { // Grayscale + Alpha
                    const pixel = row[x * 2 * bytes_per_sample ..];
                    rgba8[d] = pixel[0];
                    rgba8[d + 1] = pixel[0];
                    rgba8[d + 2] = pixel[0];
                    rgba8[d + 3] = pixel[bytes_per_sample];
                },
                6 => { // RGBA
                    const pixel = row[x * 4 * bytes_per_sample ..];
                    rgba8[d] = pixel[0];
                    rgba8[d + 1] = pixel[bytes_per_sample];
                    rgba8[d + 2] = pixel[2 * bytes_per_sample];
                    rgba8[d + 3] = pixel[3 * bytes_per_sample];
                },
                else => unreachable,
            }
        }
    }

    if (mode == .rgba8) {
        return .{ .width = width, .height = height, .data = rgba8, .mode = .rgba8 };
    }

    defer render.free(rgba8);

    const out16 = try render.alignedAlloc(u8, .fromByteUnits(16), pixel_count * 2);

    switch (mode) {
        .rgba5551 => {
            for (0..pixel_count) |i| {
                const r: u16 = rgba8[i * 4] >> 3;
                const g: u16 = rgba8[i * 4 + 1] >> 3;
                const b: u16 = rgba8[i * 4 + 2] >> 3;
                const a: u16 = if (rgba8[i * 4 + 3] >= 128) 1 else 0;
                const pixel: u16 = (r << 11) | (g << 6) | (b << 1) | a;
                out16[i * 2] = @truncate(pixel);
                out16[i * 2 + 1] = @truncate(pixel >> 8);
            }
        },
        .rgba4444 => {
            for (0..pixel_count) |i| {
                const r: u16 = rgba8[i * 4] >> 4;
                const g: u16 = rgba8[i * 4 + 1] >> 4;
                const b: u16 = rgba8[i * 4 + 2] >> 4;
                const a: u16 = rgba8[i * 4 + 3] >> 4;
                const pixel: u16 = (a << 12) | (b << 8) | (g << 4) | r;
                out16[i * 2] = @truncate(pixel);
                out16[i * 2 + 1] = @truncate(pixel >> 8);
            }
        },
        .rgba8 => unreachable,
    }
    return .{ .width = width, .height = height, .data = out16, .mode = mode };
}

fn paeth_predictor(a: u8, b: u8, c: u8) u8 {
    const ia: i32 = a;
    const ib: i32 = b;
    const ic: i32 = c;
    const p: i32 = ia + ib - ic;
    const pa = @abs(p - ia);
    const pb = @abs(p - ib);
    const pc = @abs(p - ic);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

test "PNG 8-bit and 16-bit alpha channels survive decoding" {
    const cases = [_]struct { png: []const u8, rgba: []const u8 }{
        .{
            .png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" ++
                "\x00\x00\x00\x02\x00\x00\x00\x01\x08\x06\x00\x00\x00\xf4\x22\x7f" ++
                "\x8a\x00\x00\x00\x09\x74\x45\x58\x74\x74\x65\x73\x74\x00\x73\x6b" ++
                "\x69\x70\x41\x63\xba\xf5\x00\x00\x00\x11\x49\x44\x41\x54\x78\x9c" ++
                "\x63\xf8\xcf\xd0\xf0\x5f\x40\xc1\x80\x01\x00\x10\xfc\x02\xdf\xa3" ++
                "\x50\xd1\x4e\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82",
            .rgba = &.{ 0xff, 0x00, 0x80, 0xff, 0x10, 0x20, 0x30, 0x00 },
        },
        .{
            .png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" ++
                "\x00\x00\x00\x02\x00\x00\x00\x01\x10\x06\x00\x00\x00\xa4\xb2\xa3" ++
                "\xc9\x00\x00\x00\x09\x74\x45\x58\x74\x74\x65\x73\x74\x00\x73\x6b" ++
                "\x69\x70\x41\x63\xba\xf5\x00\x00\x00\x19\x49\x44\x41\x54\x78\x9c" ++
                "\x63\xf8\x1f\xc5\x10\xd5\x10\xf5\x3f\x4a\x20\x4a\x21\xca\x20\x8a" ++
                "\x21\x0a\x00\x38\x77\x05\xaf\x05\x5d\xeb\xd7\x00\x00\x00\x00\x49" ++
                "\x45\x4e\x44\xae\x42\x60\x82",
            .rgba = &.{ 0xff, 0x00, 0x80, 0xff, 0x10, 0x20, 0x30, 0x00 },
        },
        .{
            .png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" ++
                "\x00\x00\x00\x02\x00\x00\x00\x01\x08\x04\x00\x00\x00\x5e\x2b\xb7" ++
                "\x01\x00\x00\x00\x09\x74\x45\x58\x74\x74\x65\x73\x74\x00\x73\x6b" ++
                "\x69\x70\x41\x63\xba\xf5\x00\x00\x00\x0d\x49\x44\x41\x54\x78\x9c" ++
                "\x63\x10\xaa\xf8\x27\x00\x00\x03\xc1\x01\x99\x60\x43\x16\xf8\x00" ++
                "\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82",
            .rgba = &.{ 0x12, 0x12, 0x12, 0x78, 0xfe, 0xfe, 0xfe, 0x10 },
        },
        .{
            .png = "\x89\x50\x4e\x47\x0d\x0a\x1a\x0a\x00\x00\x00\x0d\x49\x48\x44\x52" ++
                "\x00\x00\x00\x02\x00\x00\x00\x01\x10\x04\x00\x00\x00\x0e\xbb\x6b" ++
                "\x42\x00\x00\x00\x09\x74\x45\x58\x74\x74\x65\x73\x74\x00\x73\x6b" ++
                "\x69\x70\x41\x63\xba\xf5\x00\x00\x00\x11\x49\x44\x41\x54\x78\x9c" ++
                "\x63\x10\x8a\xaa\x88\xfa\x17\x25\x10\x05\x00\x0d\x21\x03\x01\xc0" ++
                "\x4a\x42\x00\x00\x00\x00\x00\x49\x45\x4e\x44\xae\x42\x60\x82",
            .rgba = &.{ 0x12, 0x12, 0x12, 0x78, 0xfe, 0xfe, 0xfe, 0x10 },
        },
    };
    for (cases) |case| {
        var reader: std.Io.Reader = .fixed(case.png);
        var decoded = try load_png_ex(std.testing.allocator, std.testing.allocator, &reader, .rgba8);
        defer decoded.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(u32, 2), decoded.width);
        try std.testing.expectEqual(@as(u32, 1), decoded.height);
        try std.testing.expectEqualSlices(u8, case.rgba, decoded.data);
    }
}

test "region copy validates before mutation and supports overlapping moves" {
    var pixels: [4 * 4 * 2]u8 = undefined;
    for (&pixels, 0..) |*pixel, i| pixel.* = @intCast(i);
    const original = pixels;
    const view: MutableView = .{ .width = 4, .height = 4, .data = &pixels, .mode = .rgba4444 };
    try std.testing.expectError(error.RegionOutOfBounds, view.copy_region(view.view(), .{ .width = 3, .height = 4 }, 2, 0));
    try std.testing.expectEqual(original, pixels);
    try view.copy_region(view.view(), .{ .width = 3, .height = 3 }, 1, 1);
    for (0..3) |y| for (0..3) |x| {
        try std.testing.expectEqualSlices(u8, original[(y * 4 + x) * 2 ..][0..2], pixels[((y + 1) * 4 + x + 1) * 2 ..][0..2]);
    };
    const shifted = pixels;
    try view.copy_region(view.view(), .{ .x = 1, .y = 1, .width = 3, .height = 3 }, 0, 0);
    for (0..3) |y| for (0..3) |x| {
        try std.testing.expectEqualSlices(u8, shifted[((y + 1) * 4 + x + 1) * 2 ..][0..2], pixels[(y * 4 + x) * 2 ..][0..2]);
    };
    try std.testing.expectError(error.InsufficientData, (View{ .width = 4, .height = 4, .data = &pixels }).validate());
}

test "image views decode compact formats" {
    const rgba5551: View = .{ .width = 1, .height = 1, .data = &.{ 0x01, 0xf8 }, .mode = .rgba5551 };
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, try rgba5551.get_pixel(0, 0));
    const rgba4444: View = .{ .width = 1, .height = 1, .data = &.{ 0x21, 0x43 }, .mode = .rgba4444 };
    try std.testing.expectEqual([4]u8{ 17, 34, 51, 68 }, try rgba4444.get_pixel(0, 0));
}
