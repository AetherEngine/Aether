const std = @import("std");
const stream = @import("stream.zig");
const PcmFormat = stream.PcmFormat;
const SoundBufferDesc = stream.SoundBufferDesc;
const sources = @import("../resources/source.zig");

pub const Error = error{ InvalidWav, UnsupportedFormat };
pub const StreamError = Error || std.Io.Reader.Error;

pub const StreamInfo = struct {
    format: PcmFormat,
    byte_length: u64,
    /// Bytes consumed before PCM, relative to the reader's initial position.
    data_offset: u64,
    riff_byte_length: u64,

    /// The input must still be positioned at the PCM payload. Both readers must
    /// remain at stable addresses during use. Trailing RIFF chunks are excluded.
    pub fn limited(self: StreamInfo, reader: *std.Io.Reader, buffer: []u8) std.Io.Reader.Limited {
        return .init(reader, .limited64(self.byte_length), buffer);
    }
};

/// Parses integer PCM (tag 1), mono/stereo, 8/16/24/32 bits. Playback support is
/// backend-specific. RIFF size, padding, rate, alignment and frame length are
/// checked. Returns a borrowed slice; bytes after the RIFF container are ignored.
pub fn parse(data: []const u8) Error!SoundBufferDesc {
    if (data.len < 12) return error.InvalidWav;
    const end64 = try riff_length(data[0..12]);
    if (end64 > data.len) return error.InvalidWav;
    const end: usize = @intCast(end64);
    var format: ?PcmFormat = null;
    var pcm: ?[]const u8 = null;
    var offset: usize = 12;
    while (offset < end) {
        if (end - offset < 8) return error.InvalidWav;
        const id = data[offset..][0..4];
        const size: usize = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
        offset += 8;
        if (size > end - offset) return error.InvalidWav;
        const chunk = data[offset..][0..size];
        if (std.mem.eql(u8, id, "fmt ")) {
            if (format != null or size < 16) return error.InvalidWav;
            format = try parse_format(chunk[0..16]);
        } else if (std.mem.eql(u8, id, "data")) {
            if (pcm != null) return error.InvalidWav;
            pcm = chunk;
        }
        offset += size;
        if (size & 1 != 0) {
            if (offset == end) return error.InvalidWav;
            offset += 1;
        }
    }
    const fmt = format orelse return error.InvalidWav;
    const bytes = pcm orelse return error.InvalidWav;
    if (bytes.len % fmt.frame_size() != 0) return error.InvalidWav;
    return .{ .format = fmt, .pcm = bytes };
}

/// Consumes only headers and leaves reader at the first PCM byte. Streaming
/// requires fmt before data. The announced payload must fit inside RIFF; actual
/// truncation inside the payload is reported by subsequent reader operations.
/// Unknown chunks and odd-byte padding are skipped within the RIFF boundary.
pub fn parse_stream(reader: *std.Io.Reader) StreamError!StreamInfo {
    var header: [12]u8 = undefined;
    try read_all(reader, &header);
    const end = try riff_length(&header);
    var offset: u64 = 12;
    var format: ?PcmFormat = null;
    while (offset < end) {
        if (end - offset < 8) return error.InvalidWav;
        var chunk: [8]u8 = undefined;
        try read_all(reader, &chunk);
        offset += 8;
        const size: u64 = std.mem.readInt(u32, chunk[4..8], .little);
        const padded = size + (size & 1);
        if (padded > end - offset) return error.InvalidWav;
        if (std.mem.eql(u8, chunk[0..4], "data")) {
            const fmt = format orelse return error.InvalidWav;
            if (size % fmt.frame_size() != 0) return error.InvalidWav;
            return .{ .format = fmt, .byte_length = size, .data_offset = offset, .riff_byte_length = end };
        }
        var consumed: u64 = 0;
        if (std.mem.eql(u8, chunk[0..4], "fmt ")) {
            if (format != null or size < 16) return error.InvalidWav;
            var fmt: [16]u8 = undefined;
            try read_all(reader, &fmt);
            format = try parse_format(&fmt);
            consumed = fmt.len;
        }
        reader.discardAll64(padded - consumed) catch |err| return read_error(err);
        offset += padded;
    }
    return error.InvalidWav;
}

fn riff_length(header: *const [12]u8) Error!u64 {
    if (!std.mem.eql(u8, header[0..4], "RIFF") or !std.mem.eql(u8, header[8..12], "WAVE")) return error.InvalidWav;
    const size = std.mem.readInt(u32, header[4..8], .little);
    if (size < 4) return error.InvalidWav;
    return @as(u64, size) + 8;
}

fn parse_format(chunk: *const [16]u8) Error!PcmFormat {
    if (std.mem.readInt(u16, chunk[0..2], .little) != 1) return error.UnsupportedFormat;
    const fmt: PcmFormat = .{
        .sample_rate = std.mem.readInt(u32, chunk[4..8], .little),
        .channels = std.mem.readInt(u16, chunk[2..4], .little),
        .bit_depth = std.mem.readInt(u16, chunk[14..16], .little),
    };
    if (fmt.sample_rate == 0 or fmt.channels == 0 or fmt.bit_depth == 0) return error.InvalidWav;
    if ((fmt.channels != 1 and fmt.channels != 2) or (fmt.bit_depth != 8 and fmt.bit_depth != 16 and fmt.bit_depth != 24 and fmt.bit_depth != 32)) return error.UnsupportedFormat;
    const alignment = fmt.frame_size();
    if (std.mem.readInt(u16, chunk[12..14], .little) != alignment) return error.InvalidWav;
    const rate = @as(u64, fmt.sample_rate) * alignment;
    if (rate != std.mem.readInt(u32, chunk[8..12], .little)) return error.InvalidWav;
    return fmt;
}

fn read_all(reader: *std.Io.Reader, buffer: []u8) StreamError!void {
    reader.readSliceAll(buffer) catch |err| return read_error(err);
}

fn read_error(err: std.Io.Reader.Error) StreamError {
    return switch (err) {
        error.EndOfStream => error.InvalidWav,
        error.ReadFailed => error.ReadFailed,
    };
}

pub const OwnedStream = struct {
    source: sources.Reader,
    info: StreamInfo,
};

const Owner = struct {
    allocator: std.mem.Allocator,
    source: sources.Reader,
    limited: std.Io.Reader.Limited,
    // PCM conversion backends can request contiguous frames.
    buffer: [4096]u8 = undefined,

    fn close(context: ?*anyopaque) void {
        const self: *Owner = @ptrCast(@alignCast(context.?));
        self.source.close();
        self.allocator.destroy(self);
    }
};

/// Opens a source and owns its reader plus a PCM-only limit. On failure every
/// acquired resource is closed. Transfer the result to Audio.create_owned_stream
/// or close result.source yourself. No complete PCM allocation is performed.
pub fn open_source(allocator: std.mem.Allocator, source: sources.Source, path: []const u8) !OwnedStream {
    var input = try source.open(path);
    errdefer input.close();
    const info = try parse_stream(input.reader);
    const owner = try allocator.create(Owner);
    owner.* = .{ .allocator = allocator, .source = input, .limited = undefined };
    owner.limited = info.limited(input.reader, &owner.buffer);
    return .{ .source = .{ .reader = &owner.limited.interface, .context = owner, .close_fn = Owner.close }, .info = info };
}

const test_wav = [_]u8{
    'R',  'I',  'F', 'F', 40,   0,    0, 0, 'W', 'A', 'V', 'E',
    'f',  'm',  't', ' ', 16,   0,    0, 0, 1,   0,   1,   0,
    0x44, 0xac, 0,   0,   0x88, 0x58, 1, 0, 2,   0,   16,  0,
    'd',  'a',  't', 'a', 4,    0,    0, 0, 1,   2,   3,   4,
};

test "wav buffer and streaming parsing agree and preserve payload position" {
    const desc = try parse(&test_wav);
    try std.testing.expectEqual(@as(u32, 44_100), desc.format.sample_rate);
    try std.testing.expectEqual(@intFromPtr(&test_wav[44]), @intFromPtr(desc.pcm.ptr));
    var reader: std.Io.Reader = .fixed(&test_wav);
    const info = try parse_stream(&reader);
    try std.testing.expectEqualDeep(desc.format, info.format);
    try std.testing.expectEqual(@as(u64, 44), info.data_offset);
    try std.testing.expectEqual(@as(u64, 4), info.byte_length);
    try std.testing.expectEqualSlices(u8, desc.pcm, try reader.take(4));
}

test "wav rejects malformed sizes, zero formats, invalid alignment and truncation" {
    const t = std.testing;
    for (0..44) |len| {
        try t.expectError(error.InvalidWav, parse(test_wav[0..len]));
        var truncated: std.Io.Reader = .fixed(test_wav[0..len]);
        try t.expectError(error.InvalidWav, parse_stream(&truncated));
    }
    for ([_]usize{ 4, 22, 24, 28, 32, 34, 40 }) |offset| {
        var bytes = test_wav;
        bytes[offset] = 0;
        if (offset == 24) bytes[25] = 0;
        // Zero-length data is valid; make its length an incomplete PCM frame.
        if (offset == 40) bytes[offset] = 3;
        try t.expectError(error.InvalidWav, parse(&bytes));
        var reader: std.Io.Reader = .fixed(&bytes);
        try t.expectError(error.InvalidWav, parse_stream(&reader));
    }
    var oversized = test_wav;
    std.mem.writeInt(u32, oversized[40..44], 0xffffffff, .little);
    var reader: std.Io.Reader = .fixed(&oversized);
    try t.expectError(error.InvalidWav, parse_stream(&reader));
}

test "wav skips odd chunks, bounds PCM, and validates announced RIFF length" {
    var bytes: [68]u8 = undefined;
    @memcpy(bytes[0..12], test_wav[0..12]);
    std.mem.writeInt(u32, bytes[4..8], 60, .little);
    @memcpy(bytes[12..22], "JUNK\x01\x00\x00\x00x\x00");
    @memcpy(bytes[22..58], test_wav[12..48]);
    @memcpy(bytes[58..68], "JUNK\x01\x00\x00\x00y\x00");
    var reader: std.Io.Reader = .fixed(&bytes);
    const info = try parse_stream(&reader);
    try std.testing.expectEqual(@as(u64, 54), info.data_offset);
    var limited = info.limited(&reader, &.{});
    var pcm: [4]u8 = undefined;
    try limited.interface.readSliceAll(&pcm);
    try std.testing.expectEqualSlices(u8, test_wav[44..48], &pcm);
    try std.testing.expectError(error.EndOfStream, limited.interface.takeByte());
    try std.testing.expectEqualSlices(u8, &pcm, (try parse(&bytes)).pcm);
}

fn check_owned(allocator: std.mem.Allocator) !void {
    var memory: sources.MemorySource = .{ .allocator = allocator, .files = &.{.{ .path = "sound.wav", .bytes = &test_wav }} };
    var owned = try open_source(allocator, memory.source(), "sound.wav");
    defer owned.source.close();

    try std.testing.expectEqualSlices(u8, test_wav[44..48], try owned.source.reader.take(4));
    try std.testing.expectError(error.EndOfStream, owned.source.reader.takeByte());
}

test "owned WAV sources close across allocation failures" {
    try check_owned(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, check_owned, .{});
}
