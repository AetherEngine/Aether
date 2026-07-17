//! Desktop audio backend -- uses SDL3 audio with an on-demand stream
//! callback. The audio thread pulls PCM from each slot's Stream reader,
//! converts to float32 stereo, applies gain/pan from the mixer, and queues
//! mixed frames to SDL.

const std = @import("std");
const sdl3 = @import("sdl3");
const audio_api = @import("../audio_api.zig");
const Stream = @import("../../audio/stream.zig").Stream;
const PcmFormat = @import("../../audio/stream.zig").PcmFormat;

const SDL_AUDIO_FLAGS = sdl3.InitFlags{ .audio = true };
const DEVICE_SAMPLE_RATE: usize = 44_100;
const DEVICE_CHANNELS: usize = 2;
const NUM_SLOTS: usize = 32;
const OUTPUT_FRAME_BYTES: usize = DEVICE_CHANNELS * @sizeOf(f32);
/// Maximum frames mixed per callback chunk.
const MAX_PERIOD_FRAMES: usize = 1024;
/// Per-slot scratch buffer: room for MAX_PERIOD_FRAMES of stereo 32-bit PCM.
const READ_BUF_SIZE: usize = MAX_PERIOD_FRAMES * 2 * 4;

// -- slot state (shared between game thread and audio thread) -----------------

const SlotState = enum(u8) {
    inactive = 0,
    /// Game thread wrote a new Stream; audio thread should pick it up.
    pending = 1,
    /// Audio thread is actively reading from the stream.
    active = 2,
    /// Stream exhausted or read error; mixer should reap.
    finished = 3,
};

const Slot = struct {
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(@intFromEnum(SlotState.inactive)),
    gain: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0))),
    pan: std.atomic.Value(u32) = std.atomic.Value(u32).init(@bitCast(@as(f32, 0))),
    stream: Stream = undefined,
    read_buf: [READ_BUF_SIZE]u8 = undefined,
};

var slots: [NUM_SLOTS]Slot = init_slots();

fn init_slots() [NUM_SLOTS]Slot {
    var s: [NUM_SLOTS]Slot = undefined;
    for (&s) |*slot| {
        slot.* = .{};
    }
    return s;
}

// -- device ------------------------------------------------------------------

var device_stream: ?sdl3.audio.Stream = null;
var sdl_audio_initialized = false;
var output_buf: [MAX_PERIOD_FRAMES * DEVICE_CHANNELS]f32 = undefined;

pub fn setup(_: std.mem.Allocator, _: std.Io) void {}

pub fn init() audio_api.InitError!void {
    sdl3.init(SDL_AUDIO_FLAGS) catch return error.AudioInitFailed;
    sdl_audio_initialized = true;
    errdefer {
        sdl3.quit(SDL_AUDIO_FLAGS);
        sdl_audio_initialized = false;
    }

    const spec = sdl3.audio.Spec{
        .format = .floating_32_bit,
        .num_channels = DEVICE_CHANNELS,
        .sample_rate = DEVICE_SAMPLE_RATE,
    };

    const stream = sdl3.audio.Device.default_playback.openStream(spec, anyopaque, data_callback, null) catch return error.AudioInitFailed;
    device_stream = stream;
    errdefer {
        stream.deinit();
        device_stream = null;
    }

    stream.resumeDevice() catch return error.AudioInitFailed;
}

pub fn deinit() void {
    if (device_stream) |stream| {
        stream.pauseDevice() catch {};
        stream.deinit();
        device_stream = null;
    }
    if (sdl_audio_initialized) {
        sdl3.quit(SDL_AUDIO_FLAGS);
        sdl_audio_initialized = false;
    }
}

pub fn update() void {}

pub fn max_voices() u32 {
    return NUM_SLOTS;
}

pub fn play_slot(slot: u8, stream: Stream) audio_api.PlaySlotError!void {
    if (slot >= NUM_SLOTS) return error.InvalidArgs;
    slots[slot].stream = stream;
    // Release ensures the stream write is visible to the audio thread.
    slots[slot].state.store(@intFromEnum(SlotState.pending), .release);
}

pub fn stop_slot(slot: u8) void {
    if (slot >= NUM_SLOTS) return;
    slots[slot].state.store(@intFromEnum(SlotState.inactive), .release);
}

pub fn set_slot_gain_pan(slot: u8, gain: f32, pan: f32) void {
    if (slot >= NUM_SLOTS) return;
    slots[slot].gain.store(@bitCast(gain), .release);
    slots[slot].pan.store(@bitCast(pan), .release);
}

pub fn is_slot_active(slot: u8) bool {
    if (slot >= NUM_SLOTS) return false;
    const state: SlotState = @enumFromInt(slots[slot].state.load(.acquire));
    return state != .inactive and state != .finished;
}

// -- audio stream callback ---------------------------------------------------

fn data_callback(
    _: ?*anyopaque,
    stream: sdl3.audio.Stream,
    additional_amount: usize,
    _: usize,
) void {
    var bytes_remaining = additional_amount;
    while (bytes_remaining > 0) {
        const frames = @min(
            MAX_PERIOD_FRAMES,
            (bytes_remaining + OUTPUT_FRAME_BYTES - 1) / OUTPUT_FRAME_BYTES,
        );
        const out = output_buf[0 .. frames * DEVICE_CHANNELS];
        fill_output(out, frames);

        const bytes = std.mem.sliceAsBytes(out);
        stream.putData(bytes) catch return;

        if (bytes_remaining <= bytes.len) break;
        bytes_remaining -= bytes.len;
    }
}

fn fill_output(out: []f32, frame_count: usize) void {
    @memset(out, 0);

    for (&slots) |*slot| {
        const raw_state = slot.state.load(.acquire);
        var state: SlotState = @enumFromInt(raw_state);

        if (state == .pending) {
            state = .active;
            slot.state.store(@intFromEnum(SlotState.active), .release);
        }
        if (state != .active) continue;

        const gain: f32 = @bitCast(slot.gain.load(.acquire));
        const pan: f32 = @bitCast(slot.pan.load(.acquire));

        // Equal-power-ish panning: clamp to [0,1] per channel.
        const left_gain = gain * std.math.clamp(1.0 - pan, 0.0, 1.0);
        const right_gain = gain * std.math.clamp(1.0 + pan, 0.0, 1.0);

        const fmt = slot.stream.format;
        const bytes_needed: usize = frame_count * @as(usize, fmt.frame_size());

        if (bytes_needed > READ_BUF_SIZE) {
            slot.state.store(@intFromEnum(SlotState.finished), .release);
            continue;
        }

        const buf = slot.read_buf[0..bytes_needed];

        slot.stream.reader.readSliceAll(buf) catch {
            slot.state.store(@intFromEnum(SlotState.finished), .release);
            continue;
        };

        mix_into(out, buf, fmt, frame_count, left_gain, right_gain);
    }
}

fn read_i16(buf: []const u8, index: usize) f32 {
    const off = index * 2;
    const raw = std.mem.readInt(i16, buf[off..][0..2], .little);
    return @as(f32, @floatFromInt(raw)) * (1.0 / 32768.0);
}

fn read_f32(buf: []const u8, index: usize) f32 {
    const off = index * 4;
    return @bitCast(std.mem.readInt(u32, buf[off..][0..4], .little));
}

fn mix_into(
    out: []f32,
    buf: []const u8,
    fmt: PcmFormat,
    frame_count: usize,
    left_gain: f32,
    right_gain: f32,
) void {
    if (fmt.bit_depth == 16) {
        if (fmt.channels == 1) {
            for (0..frame_count) |f| {
                const s = read_i16(buf, f);
                out[f * 2] += s * left_gain;
                out[f * 2 + 1] += s * right_gain;
            }
        } else {
            for (0..frame_count) |f| {
                const l = read_i16(buf, f * 2);
                const r = read_i16(buf, f * 2 + 1);
                out[f * 2] += l * left_gain;
                out[f * 2 + 1] += r * right_gain;
            }
        }
    } else if (fmt.bit_depth == 32) {
        if (fmt.channels == 1) {
            for (0..frame_count) |f| {
                const s = read_f32(buf, f);
                out[f * 2] += s * left_gain;
                out[f * 2 + 1] += s * right_gain;
            }
        } else {
            for (0..frame_count) |f| {
                out[f * 2] += read_f32(buf, f * 2) * left_gain;
                out[f * 2 + 1] += read_f32(buf, f * 2 + 1) * right_gain;
            }
        }
    }
}
