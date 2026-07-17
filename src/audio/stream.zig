const std = @import("std");
const Util = @import("../util/util.zig");

pub const PcmFormat = struct {
    sample_rate: u32,
    channels: u16,
    bit_depth: u16,

    /// Bytes consumed per sample-frame (all channels, one time-step).
    pub fn frame_size(self: PcmFormat) u32 {
        return @as(u32, self.channels) * (self.bit_depth / 8);
    }
};

pub const SoundBufferHandleTag = enum {};
pub const SoundBufferHandle = Util.Handle(SoundBufferHandleTag);

pub const StreamingSoundHandleTag = enum {};
pub const StreamingSoundHandle = Util.Handle(StreamingSoundHandleTag);

pub const SoundBufferDesc = struct {
    format: PcmFormat,
    pcm: []const u8,
};

pub const StreamingSoundDesc = struct {
    reader: *std.Io.Reader,
    format: PcmFormat,
    /// Total bytes of PCM data available, null if unknown / infinite.
    byte_length: ?u64 = null,
};

pub const SlotSource = union(enum) {
    buffer: BufferSource,
    stream: StreamSource,

    pub const BufferSource = struct {
        format: PcmFormat,
        pcm: []const u8,
        cursor: *std.atomic.Value(usize),
    };

    pub const StreamSource = struct {
        reader: *std.Io.Reader,
        format: PcmFormat,
        byte_length: ?u64 = null,
    };
};
