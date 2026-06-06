//! Switch audio backend -- audout with software mixing.
//!
//! audout exposes one 48 kHz stereo i16 output stream, so this backend mixes
//! Aether's slots into a ring of audout buffers. A small nearest-neighbor
//! resampler keeps the existing 44.1 kHz test WAVs playable.

const std = @import("std");
const Stream = @import("../../audio/stream.zig").Stream;
const PcmFormat = @import("../../audio/stream.zig").PcmFormat;
const c = @import("../nintendo_c.zig").c;

const DEVICE_SAMPLE_RATE: u32 = 48_000;
const DEVICE_CHANNELS: usize = 2;
const NUM_SLOTS: usize = 24;
const BUFFER_COUNT: usize = 3;
const SAMPLES_PER_BUF: usize = 2048;
const OUTPUT_BYTES: usize = SAMPLES_PER_BUF * DEVICE_CHANNELS * @sizeOf(i16);
const OUTPUT_BUFFER_BYTES: usize = std.mem.alignForward(usize, OUTPUT_BYTES, 0x1000);
const TOTAL_OUTPUT_BYTES: usize = BUFFER_COUNT * OUTPUT_BUFFER_BYTES;
const FP_ONE: u64 = 1 << 32;

const SlotState = enum(u8) {
    inactive = 0,
    pending = 1,
    active = 2,
    finished = 3,
};

const Slot = struct {
    state: SlotState = .inactive,
    gain: f32 = 0,
    pan: f32 = 0,
    stream: Stream = undefined,
    format: PcmFormat = .{ .sample_rate = 44_100, .channels = 1, .bit_depth = 16 },
    step_fp: u64 = FP_ONE,
    phase_fp: u64 = 0,
    current_left: i16 = 0,
    current_right: i16 = 0,
};

var slots: [NUM_SLOTS]Slot = init_slots();
var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;
var output_data: ?[*]u8 = null;
var buffers: [BUFFER_COUNT]c.AudioOutBuffer = undefined;
var initialized: bool = false;

fn init_slots() [NUM_SLOTS]Slot {
    var s: [NUM_SLOTS]Slot = undefined;
    for (&s) |*slot| {
        slot.* = .{};
    }
    return s;
}

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    audio_alloc = alloc;
    audio_io = io;
}

pub fn init() anyerror!void {
    _ = audio_alloc;
    _ = audio_io;

    output_data = @ptrCast(c.memalign(0x1000, TOTAL_OUTPUT_BYTES) orelse return error.AudioInitFailed);
    @memset(output_data.?[0..TOTAL_OUTPUT_BYTES], 0);

    if (c.audoutInitialize() != 0) {
        free_output();
        return error.AudioInitFailed;
    }

    if (c.audoutStartAudioOut() != 0) {
        c.audoutExit();
        free_output();
        return error.AudioInitFailed;
    }

    initialized = true;

    for (&buffers, 0..) |*buf, i| {
        buf.* = .{
            .next = null,
            .buffer = @ptrCast(output_data.? + i * OUTPUT_BUFFER_BYTES),
            .buffer_size = OUTPUT_BUFFER_BYTES,
            .data_size = OUTPUT_BYTES,
            .data_offset = 0,
        };
        if (c.audoutAppendAudioOutBuffer(buf) != 0) {
            _ = c.audoutStopAudioOut();
            c.audoutExit();
            initialized = false;
            free_output();
            return error.AudioInitFailed;
        }
    }
}

pub fn deinit() void {
    if (initialized) {
        _ = c.audoutStopAudioOut();
        c.audoutExit();
        initialized = false;
    }

    free_output();

    for (&slots) |*slot| {
        slot.state = .inactive;
    }
}

pub fn update() void {
    if (!initialized) return;

    while (true) {
        var released: ?*c.AudioOutBuffer = null;
        var released_count: u32 = 0;
        if (c.audoutGetReleasedAudioOutBuffer(&released, &released_count) != 0) return;
        if (released_count == 0 or released == null) return;

        const buf = released.?;
        fill_output_buffer(buf);
        _ = c.audoutAppendAudioOutBuffer(buf);
    }
}

pub fn max_voices() u32 {
    return NUM_SLOTS;
}

pub fn play_slot(slot: u8, stream: Stream) anyerror!void {
    if (slot >= NUM_SLOTS) return error.InvalidArgs;
    if (!format_supported(stream.format)) return error.UnsupportedFormat;

    const i: usize = slot;
    slots[i].stream = stream;
    slots[i].format = stream.format;
    slots[i].step_fp = (@as(u64, stream.format.sample_rate) << 32) / DEVICE_SAMPLE_RATE;
    slots[i].phase_fp = 0;
    slots[i].current_left = 0;
    slots[i].current_right = 0;
    slots[i].state = .pending;
}

pub fn stop_slot(slot: u8) void {
    if (slot >= NUM_SLOTS) return;
    slots[slot].state = .inactive;
}

pub fn set_slot_gain_pan(slot: u8, gain: f32, pan: f32) void {
    if (slot >= NUM_SLOTS) return;
    slots[slot].gain = gain;
    slots[slot].pan = pan;
}

pub fn is_slot_active(slot: u8) bool {
    if (slot >= NUM_SLOTS) return false;
    return slots[slot].state != .inactive and slots[slot].state != .finished;
}

fn fill_output_buffer(buf: *c.AudioOutBuffer) void {
    const out: [*]i16 = @ptrCast(@alignCast(buf.buffer.?));

    for (0..SAMPLES_PER_BUF) |frame| {
        var left_acc: i32 = 0;
        var right_acc: i32 = 0;

        for (&slots) |*slot| {
            if (slot.state == .pending) {
                if (read_next_sample(slot)) {
                    slot.state = .active;
                } else {
                    slot.state = .finished;
                }
            }

            if (slot.state != .active) continue;

            const left_gain = slot.gain * std.math.clamp(1.0 - slot.pan, 0.0, 1.0);
            const right_gain = slot.gain * std.math.clamp(1.0 + slot.pan, 0.0, 1.0);
            const left_vol: i32 = @intFromFloat(std.math.clamp(left_gain, 0.0, 1.0) * 32768.0);
            const right_vol: i32 = @intFromFloat(std.math.clamp(right_gain, 0.0, 1.0) * 32768.0);

            left_acc += (@as(i32, slot.current_left) * left_vol) >> 15;
            right_acc += (@as(i32, slot.current_right) * right_vol) >> 15;

            advance_sample(slot);
        }

        out[frame * 2] = clamp_i16(left_acc);
        out[frame * 2 + 1] = clamp_i16(right_acc);
    }

    buf.data_size = OUTPUT_BYTES;
    buf.data_offset = 0;
}

fn advance_sample(slot: *Slot) void {
    slot.phase_fp +%= slot.step_fp;
    while (slot.phase_fp >= FP_ONE) {
        slot.phase_fp -= FP_ONE;
        if (!read_next_sample(slot)) {
            slot.state = .finished;
            return;
        }
    }
}

fn read_next_sample(slot: *Slot) bool {
    var tmp: [4]u8 = undefined;
    const frame_size = slot.format.frame_size();
    if (frame_size > tmp.len) return false;

    slot.stream.reader.readSliceAll(tmp[0..frame_size]) catch return false;

    if (slot.format.channels == 1) {
        const s = std.mem.readInt(i16, tmp[0..2], .little);
        slot.current_left = s;
        slot.current_right = s;
    } else {
        slot.current_left = std.mem.readInt(i16, tmp[0..2], .little);
        slot.current_right = std.mem.readInt(i16, tmp[2..4], .little);
    }

    return true;
}

fn clamp_i16(v: i32) i16 {
    return @intCast(std.math.clamp(v, std.math.minInt(i16), std.math.maxInt(i16)));
}

fn free_output() void {
    if (output_data) |data| {
        c.free(data);
        output_data = null;
    }
}

fn format_supported(fmt: PcmFormat) bool {
    return fmt.bit_depth == 16 and (fmt.channels == 1 or fmt.channels == 2);
}
