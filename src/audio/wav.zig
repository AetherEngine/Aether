const std = @import("std");
const stream = @import("stream.zig");
const PcmFormat = stream.PcmFormat;
const Stream = stream.Stream;

/// Parse a WAV/RIFF header and return a `Stream` whose reader is positioned
/// at the start of the PCM data.  Only uncompressed PCM (format tag 1) is
/// supported.
pub fn open(reader: *std.Io.Reader) !Stream {
    // ---- RIFF header ----
    var riff_hdr: [12]u8 = undefined;
    try reader.readSliceAll(&riff_hdr);

    if (!std.mem.eql(u8, riff_hdr[0..4], "RIFF"))
        return error.InvalidWav;
    if (!std.mem.eql(u8, riff_hdr[8..12], "WAVE"))
        return error.InvalidWav;

    // ---- walk chunks until we have both "fmt " and "data" ----
    var format: ?PcmFormat = null;
    var data_bytes: ?u64 = null;

    while (true) {
        var chunk_hdr: [8]u8 = undefined;
        reader.readSliceAll(&chunk_hdr) catch break;

        const chunk_id = chunk_hdr[0..4];
        const chunk_size: u32 = std.mem.readInt(u32, chunk_hdr[4..8], .little);

        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16) return error.InvalidWav;

            var fmt_buf: [16]u8 = undefined;
            try reader.readSliceAll(&fmt_buf);

            const audio_format = std.mem.readInt(u16, fmt_buf[0..2], .little);
            if (audio_format != 1) return error.UnsupportedFormat; // PCM only

            const channels = std.mem.readInt(u16, fmt_buf[2..4], .little);
            const sample_rate = std.mem.readInt(u32, fmt_buf[4..8], .little);
            // byte_rate  = fmt_buf[8..12]  (skip)
            // block_align = fmt_buf[12..14] (skip)
            const bit_depth = std.mem.readInt(u16, fmt_buf[14..16], .little);

            format = .{
                .sample_rate = sample_rate,
                .channels = channels,
                .bit_depth = bit_depth,
            };

            // skip any extra fmt bytes
            if (chunk_size > 16) {
                try skip_bytes(reader, chunk_size - 16);
            }
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            data_bytes = chunk_size;
            break; // reader is now positioned at PCM data
        } else {
            // skip unknown chunk
            try skip_bytes(reader, chunk_size);
        }

        // WAV chunks are 2-byte aligned; skip pad byte if odd size
        if (chunk_size & 1 != 0) {
            try skip_bytes(reader, 1);
        }
    }

    const fmt = format orelse return error.InvalidWav;

    return .{
        .reader = reader,
        .format = fmt,
        .byte_length = data_bytes,
    };
}

fn skip_bytes(reader: *std.Io.Reader, n: u32) !void {
    var remaining: usize = n;
    var buf: [256]u8 = undefined;
    while (remaining > 0) {
        const to_read = @min(remaining, buf.len);
        try reader.readSliceAll(buf[0..to_read]);
        remaining -= to_read;
    }
}
