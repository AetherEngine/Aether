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

    pub fn format(self: SlotSource) PcmFormat {
        return switch (self) {
            .buffer => |source| source.format,
            .stream => |source| source.format,
        };
    }
};

pub const InitError = error{
    OutOfMemory,
    AudioInitFailed,
};

pub const PlaySlotError = error{
    OutOfMemory,
    InvalidArgs,
    UnsupportedFormat,
    AudioHostRejectedStream,
};

/// PCM output slots; voice scheduling and spatial math belong to Audio.
/// Backends borrow PCM and cursors; deinit must stop all workers before returning.
pub const Interface = struct {
    init: fn (std.mem.Allocator, std.Io) InitError!void,
    deinit: fn () void,
    /// Per-frame bookkeeping, called from the game thread.
    update: fn () void,

    /// Number of simultaneous voices the backend can output.
    max_voices: fn () u32,
    /// Begin reading PCM from `source` on `slot`. Implicitly stops any
    /// previous stream on that slot.
    play_slot: fn (u8, SlotSource) PlaySlotError!void,
    /// Stop reading on `slot`.
    stop_slot: fn (u8) void,
    /// Set output gain [0,1] and stereo pan [-1,1] for `slot`.
    set_slot_gain_pan: fn (u8, f32, f32) void,
    /// True while the slot's stream has not been exhausted or stopped.
    is_slot_active: fn (u8) bool,
};

pub fn assert_impl(comptime Backend: type) void {
    @import("contract.zig").assert_impl("audio", Backend, Interface);
}
