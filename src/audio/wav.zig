const std = @import("std");
const stream = @import("stream.zig");
const PcmFormat = stream.PcmFormat;
const SoundBufferDesc = stream.SoundBufferDesc;

pub const Error = error{
    InvalidWav,
    UnsupportedFormat,
};

/// Parse a WAV/RIFF byte buffer and return a borrowed PCM slice.
/// Only uncompressed PCM (format tag 1) is supported.
pub fn parse(data: []const u8) Error!SoundBufferDesc {
    if (data.len < 12) return error.InvalidWav;
    if (!std.mem.eql(u8, data[0..4], "RIFF")) return error.InvalidWav;
    if (!std.mem.eql(u8, data[8..12], "WAVE")) return error.InvalidWav;

    var format: ?PcmFormat = null;
    var pcm: ?[]const u8 = null;
    var offset: usize = 12;

    while (offset + 8 <= data.len) {
        const chunk_id = data[offset..][0..4];
        const chunk_size: usize = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
        offset += 8;

        if (chunk_size > data.len - offset) return error.InvalidWav;
        const chunk = data[offset..][0..chunk_size];

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk.len < 16) return error.InvalidWav;

            const audio_format = std.mem.readInt(u16, chunk[0..2], .little);
            if (audio_format != 1) return error.UnsupportedFormat;

            format = .{
                .sample_rate = std.mem.readInt(u32, chunk[4..8], .little),
                .channels = std.mem.readInt(u16, chunk[2..4], .little),
                .bit_depth = std.mem.readInt(u16, chunk[14..16], .little),
            };
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            pcm = chunk;
        }

        offset += chunk_size;
        if (chunk_size & 1 != 0) offset += 1;
    }

    const fmt = format orelse return error.InvalidWav;
    const bytes = pcm orelse return error.InvalidWav;
    if (bytes.len % fmt.frame_size() != 0) return error.InvalidWav;

    return .{
        .format = fmt,
        .pcm = bytes,
    };
}

test "wav parse returns borrowed pcm slice" {
    const data = [_]u8{
        'R',  'I',  'F', 'F', 40,   0,    0, 0, 'W', 'A', 'V', 'E',
        'f',  'm',  't', ' ', 16,   0,    0, 0, 1,   0,   1,   0,
        0x44, 0xac, 0,   0,   0x88, 0x58, 1, 0, 2,   0,   16,  0,
        'd',  'a',  't', 'a', 4,    0,    0, 0, 1,   2,   3,   4,
    };

    const desc = try parse(&data);
    try std.testing.expectEqual(@as(u32, 44_100), desc.format.sample_rate);
    try std.testing.expectEqual(@as(u16, 1), desc.format.channels);
    try std.testing.expectEqual(@as(u16, 16), desc.format.bit_depth);
    try std.testing.expectEqual(@intFromPtr(&data[44]), @intFromPtr(desc.pcm.ptr));
    try std.testing.expectEqualSlices(u8, data[44..48], desc.pcm);
}
