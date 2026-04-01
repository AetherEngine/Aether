const std = @import("std");
const flate = std.compress.flate;

pub const ColorMode = enum { rgba8, rgba5551, rgba4444 };

pub const Image = struct {
    width: u32,
    height: u32,
    data: []align(16) u8,
    mode: ColorMode,

    pub fn deinit(self: *Image, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

const png_signature = "\x89PNG\r\n\x1a\n";

/// Decode PNG from a reader → RGBA8. Caller owns returned slice.
pub fn load_png(allocator: std.mem.Allocator, reader: *std.Io.Reader) ![]u8 {
    const img = try load_png_ex(allocator, allocator, reader, .rgba8);
    return img.data;
}

/// Decode PNG from a reader with explicit color mode. Caller owns image.data.
/// `scratch` is used for all temporary allocations during decoding.
/// `render` is used for the final pixel buffer stored in `image.data`.
pub fn load_png_ex(scratch: std.mem.Allocator, render: std.mem.Allocator, reader: *std.Io.Reader, mode: ColorMode) !Image {
    const allocator = scratch;

    // Verify PNG signature
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
    var trns_alpha: [256]u8 = [_]u8{255} ** 256;
    var trns_len: u32 = 0;
    var trns_gray: u16 = 0;
    var trns_rgb: [3]u16 = .{ 0, 0, 0 };
    var has_trns = false;

    var idat_buf: std.ArrayList(u8) = .empty;
    defer idat_buf.deinit(allocator);

    // Parse chunks
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
            if (compression_method != 0) return error.InvalidPNG;
            if (filter_method != 0) return error.InvalidPNG;
            switch (color_type) {
                0 => switch (bit_depth) {
                    8, 16 => {},
                    else => return error.UnsupportedColorType,
                },
                2 => switch (bit_depth) {
                    8, 16 => {},
                    else => return error.UnsupportedColorType,
                },
                3 => switch (bit_depth) {
                    1, 2, 4, 8 => {},
                    else => return error.UnsupportedColorType,
                },
                4 => switch (bit_depth) {
                    8, 16 => {},
                    else => return error.UnsupportedColorType,
                },
                6 => switch (bit_depth) {
                    8, 16 => {},
                    else => return error.UnsupportedColorType,
                },
                else => return error.UnsupportedColorType,
            }
            ihdr_found = true;
            // Skip remaining bytes + CRC
            try skipBytes(reader, length - 13 + 4);
        } else if (std.mem.eql(u8, chunk_type, "PLTE")) {
            const chunk_data = try scratch.alloc(u8, length);
            defer scratch.free(chunk_data);
            try reader.readSliceAll(chunk_data);
            palette_len = @intCast(length / 3);
            for (0..palette_len) |i| {
                palette[i] = .{ chunk_data[i * 3], chunk_data[i * 3 + 1], chunk_data[i * 3 + 2] };
            }
            // Skip CRC
            try skipBytes(reader, 4);
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
            // Skip CRC
            try skipBytes(reader, 4);
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            const prev_len = idat_buf.items.len;
            try idat_buf.resize(allocator, prev_len + length);
            try reader.readSliceAll(idat_buf.items[prev_len..]);
            // Skip CRC
            try skipBytes(reader, 4);
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            break;
        } else {
            // Skip unknown chunk data + CRC
            try skipBytes(reader, length + 4);
        }
    }

    if (!ihdr_found) return error.InvalidPNG;
    if (width == 0 or height == 0) return error.InvalidPNG;

    const channels: u32 = switch (color_type) {
        0 => 1,
        2 => 3,
        3 => 1,
        4 => 2,
        6 => 4,
        else => return error.UnsupportedColorType,
    };
    const bytes_per_sample: u32 = if (bit_depth == 16) 2 else 1;
    // Raw bytes per scanline (before filter byte)
    const raw_stride: u32 = if (color_type == 3 and bit_depth < 8)
        (width * bit_depth + 7) / 8
    else
        width * channels * bytes_per_sample;

    // Decompress all IDAT data (zlib-wrapped DEFLATE)
    var in_reader: std.Io.Reader = .fixed(idat_buf.items);
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    var decomp: flate.Decompress = .init(&in_reader, .zlib, &.{});
    _ = try decomp.reader.streamRemaining(&aw.writer);
    const raw = aw.written();

    const expected_raw_size: usize = @as(usize, height) * (1 + raw_stride);
    if (raw.len < expected_raw_size) return error.InvalidPNG;

    // bpp for filter purposes = max(1, bit_depth * channels / 8)
    const bpp: u32 = @max(1, @as(u32, bit_depth) * channels / 8);

    // Unfilter scanlines into a flat buffer
    const unfiltered = try allocator.alloc(u8, @as(usize, height) * raw_stride);
    defer allocator.free(unfiltered);

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
                    dst[i] +%= paethPredictor(a, b, c);
                }
            },
            else => return error.InvalidFilter,
        }
    }

    // Convert unfiltered scanlines to RGBA8
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
                    if (bit_depth == 16) {
                        const v: u8 = row[x * 4];
                        const a: u8 = row[x * 4 + 2];
                        rgba8[d] = v;
                        rgba8[d + 1] = v;
                        rgba8[d + 2] = v;
                        rgba8[d + 3] = a;
                    } else {
                        const v = row[x * 2];
                        const a = row[x * 2 + 1];
                        rgba8[d] = v;
                        rgba8[d + 1] = v;
                        rgba8[d + 2] = v;
                        rgba8[d + 3] = a;
                    }
                },
                6 => { // RGBA
                    if (bit_depth == 16) {
                        rgba8[d] = row[x * 8];
                        rgba8[d + 1] = row[x * 8 + 2];
                        rgba8[d + 2] = row[x * 8 + 4];
                        rgba8[d + 3] = row[x * 8 + 6];
                    } else {
                        rgba8[d] = row[x * 4];
                        rgba8[d + 1] = row[x * 4 + 1];
                        rgba8[d + 2] = row[x * 4 + 2];
                        rgba8[d + 3] = row[x * 4 + 3];
                    }
                },
                else => unreachable,
            }
        }
    }

    if (mode == .rgba8) {
        return .{ .width = width, .height = height, .data = rgba8, .mode = .rgba8 };
    }

    // 16-bit conversion: allocate half the buffer
    const out16 = render.alignedAlloc(u8, .fromByteUnits(16), pixel_count * 2) catch |err| {
        render.free(rgba8);
        return err;
    };

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
    render.free(rgba8);

    return .{ .width = width, .height = height, .data = out16, .mode = mode };
}

fn skipBytes(reader: *std.Io.Reader, n: usize) !void {
    var remaining = n;
    var buf: [256]u8 = undefined;
    while (remaining > 0) {
        const to_read = @min(remaining, buf.len);
        try reader.readSliceAll(buf[0..to_read]);
        remaining -= to_read;
    }
}

fn paethPredictor(a: u8, b: u8, c: u8) u8 {
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
