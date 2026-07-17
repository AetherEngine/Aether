const std = @import("std");
const SlotSource = @import("../audio/stream.zig").SlotSource;

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

/// The contract every audio backend must satisfy. Backends are thin
/// slot-based PCM outputs -- all scheduling, priority, and spatial math
/// lives in the platform-independent mixer (`audio/mixer.zig`).
///
/// The backend's audio thread pulls PCM from the assigned slot source,
/// applies the gain/pan set by the mixer, and writes to the output device.
pub const Interface = struct {
    setup: fn (std.mem.Allocator, std.Io) void,
    init: fn () InitError!void,
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

/// Verify at comptime that `Backend` exposes every decl in `Interface`
/// with the exact expected signature.
pub fn assert_impl(comptime Backend: type) void {
    inline for (std.meta.fields(Interface)) |f| {
        if (!@hasDecl(Backend, f.name)) {
            @compileError("audio backend " ++ @typeName(Backend) ++ " is missing decl: " ++ f.name);
        }
        const Actual = @TypeOf(@field(Backend, f.name));
        if (Actual != f.type) {
            @compileError("audio backend " ++ @typeName(Backend) ++ "." ++ f.name ++
                " has type " ++ @typeName(Actual) ++ ", expected " ++ @typeName(f.type));
        }
    }
}
