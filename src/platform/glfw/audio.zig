//! Desktop audio backend — uses zaudio (miniaudio) with a low-level device
//! callback. The audio thread pulls PCM from each slot's Stream reader,
//! converts to float32 stereo, applies gain/pan from the mixer, and writes
//! to the output device.

const std = @import("std");
const zaudio = @import("zaudio");
const Stream = @import("../../audio/stream.zig").Stream;
const PcmFormat = @import("../../audio/stream.zig").PcmFormat;

const DEVICE_SAMPLE_RATE: u32 = 44_100;
const DEVICE_CHANNELS: u32 = 2;
const NUM_SLOTS: usize = 32;
/// Maximum frames the device callback will request per invocation.
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

var device: ?*zaudio.Device = null;
var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    audio_alloc = alloc;
    audio_io = io;
}

pub fn init() anyerror!void {
    zaudio.init(audio_alloc);

    var config = zaudio.Device.Config.init(.playback);
    config.playback.format = .float32;
    config.playback.channels = DEVICE_CHANNELS;
    config.sample_rate = DEVICE_SAMPLE_RATE;
    config.data_callback = data_callback;

    device = try zaudio.Device.create(null, config);
    try device.?.start();
}

pub fn deinit() void {
    if (device) |d| {
        d.stop() catch {};
        d.destroy();
        device = null;
    }
    zaudio.deinit();
}

pub fn update() void {}

pub fn max_voices() u32 {
    return NUM_SLOTS;
}

pub fn play_slot(slot: u8, stream: Stream) anyerror!void {
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

// -- audio thread callback ---------------------------------------------------

fn data_callback(
    _: *zaudio.Device,
    raw_output: ?*anyopaque,
    _: ?*const anyopaque,
    frame_count: u32,
) callconv(.c) void {
    const out: [*]f32 = @ptrCast(@alignCast(raw_output orelse return));
    const total_samples: usize = @as(usize, frame_count) * DEVICE_CHANNELS;

    // Start with silence.
    @memset(out[0..total_samples], 0);

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
        const bytes_needed: usize = @as(usize, frame_count) * fmt.frame_size();

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
    out: [*]f32,
    buf: []const u8,
    fmt: PcmFormat,
    frame_count: u32,
    left_gain: f32,
    right_gain: f32,
) void {
    const frames: usize = frame_count;

    if (fmt.bit_depth == 16) {
        if (fmt.channels == 1) {
            for (0..frames) |f| {
                const s = read_i16(buf, f);
                out[f * 2] += s * left_gain;
                out[f * 2 + 1] += s * right_gain;
            }
        } else {
            for (0..frames) |f| {
                const l = read_i16(buf, f * 2);
                const r = read_i16(buf, f * 2 + 1);
                out[f * 2] += l * left_gain;
                out[f * 2 + 1] += r * right_gain;
            }
        }
    } else if (fmt.bit_depth == 32) {
        if (fmt.channels == 1) {
            for (0..frames) |f| {
                const s = read_f32(buf, f);
                out[f * 2] += s * left_gain;
                out[f * 2 + 1] += s * right_gain;
            }
        } else {
            for (0..frames) |f| {
                out[f * 2] += read_f32(buf, f * 2) * left_gain;
                out[f * 2 + 1] += read_f32(buf, f * 2 + 1) * right_gain;
            }
        }
    }
}
