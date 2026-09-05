const std = @import("std");
const Util = @import("../util/util.zig");

pub const PcmFormat = @import("platform").audio_api.PcmFormat;

pub const SoundBufferHandleTag = enum {};
pub const SoundBufferHandle = Util.HandleType(SoundBufferHandleTag);

pub const StreamingSoundHandleTag = enum {};
pub const StreamingSoundHandle = Util.HandleType(StreamingSoundHandleTag);

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

pub const SlotSource = @import("platform").audio_api.SlotSource;
