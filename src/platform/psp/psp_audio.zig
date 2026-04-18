//! PSP audio backend — single hardware channel with software mixing.
//!
//! Reserves one stereo sceAudio channel and runs a dedicated audio thread
//! that mixes all active slots into a stereo i16 double buffer.
//! `output_panned_blocking` provides natural timing — the call blocks until
//! the hardware consumes the previous buffer, then queues the new one.

const std = @import("std");
const sdk = @import("pspsdk");
const Stream = @import("../../audio/stream.zig").Stream;
const PcmFormat = @import("../../audio/stream.zig").PcmFormat;

const NUM_SLOTS: usize = 8;
const SAMPLES_PER_BUF: usize = 1024;
/// Per-slot scratch: room for SAMPLES_PER_BUF of stereo i16.
const READ_BUF_SIZE: usize = SAMPLES_PER_BUF * 2 * 2 * 8;
/// Output buffer: SAMPLES_PER_BUF stereo i16 frames.
const OUTPUT_BUF_BYTES: usize = SAMPLES_PER_BUF * 2 * 2;
const PSP_VOLUME_MAX: i32 = 0x8000;

// -- slot state (shared between game thread and audio thread) -----------------

const SlotState = enum(u8) {
    inactive = 0,
    pending = 1,
    active = 2,
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

// -- module state -------------------------------------------------------------

var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;
var hw_channel: i32 = -1;
var thread_id: sdk.SceUID = -1;
var running: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

/// Double output buffers, 64-byte aligned for PSP DMA.
var output_bufs: [2][OUTPUT_BUF_BYTES]u8 align(64) = .{ .{0} ** BUF_COUNT, .{0} ** BUF_COUNT };
const BUF_COUNT = OUTPUT_BUF_BYTES;

// -- public interface ---------------------------------------------------------

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    audio_alloc = alloc;
    audio_io = io;
}

pub fn init() anyerror!void {
    hw_channel = sdk.audio.ch_reserve(sdk.audio.next_channel, @intCast(SAMPLES_PER_BUF), .stereo) catch
        return error.AudioInitFailed;

    running.store(1, .release);

    thread_id = sdk.kernel.create_thread(
        "aether_audio",
        audio_thread_fn,
        0x12,
        8 * 1024,
        .{ .user = true },
        null,
    ) catch {
        sdk.audio.ch_release(hw_channel) catch {};
        hw_channel = -1;
        return error.AudioInitFailed;
    };

    sdk.kernel.start_thread(thread_id, 0, null) catch {
        sdk.kernel.delete_thread(thread_id) catch {};
        sdk.audio.ch_release(hw_channel) catch {};
        hw_channel = -1;
        thread_id = -1;
        return error.AudioInitFailed;
    };
}

pub fn deinit() void {
    if (hw_channel < 0) return;

    running.store(0, .release);

    var timeout: u32 = 500_000;
    sdk.kernel.wait_thread_end(thread_id, &timeout) catch {};
    sdk.kernel.delete_thread(thread_id) catch {};
    thread_id = -1;

    sdk.audio.ch_release(hw_channel) catch {};
    hw_channel = -1;
}

pub fn update() void {}

pub fn max_voices() u32 {
    return NUM_SLOTS;
}

pub fn play_slot(slot: u8, stream: Stream) anyerror!void {
    if (slot >= NUM_SLOTS) return error.InvalidArgs;
    slots[slot].stream = stream;
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

// -- audio thread -------------------------------------------------------------

fn audio_thread_fn(_: usize, _: ?*anyopaque) callconv(.c) c_int {
    var cur: u1 = 0;

    while (running.load(.acquire) != 0) {
        fill_buffer(&output_bufs[cur]);

        sdk.audio.output_panned_blocking(
            hw_channel,
            PSP_VOLUME_MAX,
            PSP_VOLUME_MAX,
            @ptrCast(&output_bufs[cur]),
        ) catch {};

        cur ^= 1;
    }

    return 0;
}

fn fill_buffer(buf: *[OUTPUT_BUF_BYTES]u8) void {
    @memset(buf, 0);

    const out: [*]i16 = @ptrCast(@alignCast(buf));

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

        const left_gain = gain * std.math.clamp(1.0 - pan, 0.0, 1.0);
        const right_gain = gain * std.math.clamp(1.0 + pan, 0.0, 1.0);
        const left_vol: i32 = @intFromFloat(std.math.clamp(left_gain, 0.0, 1.0) * 32768.0);
        const right_vol: i32 = @intFromFloat(std.math.clamp(right_gain, 0.0, 1.0) * 32768.0);

        const fmt = slot.stream.format;
        const bytes_needed: usize = SAMPLES_PER_BUF * fmt.frame_size();

        if (bytes_needed > READ_BUF_SIZE) {
            slot.state.store(@intFromEnum(SlotState.finished), .release);
            continue;
        }

        const read_buf = slot.read_buf[0..bytes_needed];

        slot.stream.reader.readSliceAll(read_buf) catch {
            slot.state.store(@intFromEnum(SlotState.finished), .release);
            continue;
        };

        mix_into_i16(out, read_buf, fmt, left_vol, right_vol);
    }
}

// -- integer mixing -----------------------------------------------------------

fn mix_into_i16(
    out: [*]i16,
    buf: []const u8,
    fmt: PcmFormat,
    left_vol: i32,
    right_vol: i32,
) void {
    if (fmt.bit_depth != 16) return;

    if (fmt.channels == 1) {
        for (0..SAMPLES_PER_BUF) |f| {
            const s: i32 = std.mem.readInt(i16, buf[f * 2 ..][0..2], .little);
            out[f * 2] +|= @intCast((s * left_vol) >> 15);
            out[f * 2 + 1] +|= @intCast((s * right_vol) >> 15);
        }
    } else {
        for (0..SAMPLES_PER_BUF) |f| {
            const l: i32 = std.mem.readInt(i16, buf[f * 4 ..][0..2], .little);
            const r: i32 = std.mem.readInt(i16, buf[f * 4 + 2 ..][0..2], .little);
            out[f * 2] +|= @intCast((l * left_vol) >> 15);
            out[f * 2 + 1] +|= @intCast((r * right_vol) >> 15);
        }
    }
}
