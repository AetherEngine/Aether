const std = @import("std");

pub const PcmFormat = struct {
    sample_rate: u32,
    channels: u16,
    bit_depth: u16,

    /// Bytes consumed per sample-frame (all channels, one time-step).
    pub fn frame_size(self: PcmFormat) u32 {
        return @as(u32, self.channels) * (self.bit_depth / 8);
    }
};

pub const Stream = struct {
    reader: *std.Io.Reader,
    format: PcmFormat,
    /// Total bytes of PCM data available, null if unknown / infinite.
    byte_length: ?u64 = null,
};
