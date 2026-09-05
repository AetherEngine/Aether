//! Mixes and resamples slots into 48 kHz stereo PCM16 audout buffers.

const std = @import("std");
const audio_api = @import("../audio_api.zig");
const SlotSource = audio_api.SlotSource;
const PcmFormat = audio_api.PcmFormat;
const c = @import("c.zig").switch_c;

const device_sample_rate: u32 = 48_000;
const device_channels: usize = 2;
const num_slots: usize = 24;
const buffer_count: usize = 3;
const samples_per_buf: usize = 2048;
const output_bytes: usize = samples_per_buf * device_channels * @sizeOf(i16);
const output_buffer_bytes: usize = std.mem.alignForward(usize, output_bytes, 0x1000);
const total_output_bytes: usize = buffer_count * output_buffer_bytes;
const fp_one: u64 = 1 << 32;

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
    source: SlotSource = undefined,
    format: PcmFormat = .{ .sample_rate = 44_100, .channels = 1, .bit_depth = 16 },
    step_fp: u64 = fp_one,
    phase_fp: u64 = 0,
    current_left: i16 = 0,
    current_right: i16 = 0,
};

var slots: [num_slots]Slot = @splat(.{});
var output_data: ?[*]u8 = null;
var buffers: [buffer_count]c.AudioOutBuffer = undefined;
var initialized: bool = false;

pub fn init(_: std.mem.Allocator, _: std.Io) audio_api.InitError!void {
    output_data = @ptrCast(c.memalign(0x1000, total_output_bytes) orelse return error.AudioInitFailed);
    @memset(output_data.?[0..total_output_bytes], 0);

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
            .buffer = @ptrCast(output_data.? + i * output_buffer_bytes),
            .buffer_size = output_buffer_bytes,
            .data_size = output_bytes,
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
    return num_slots;
}

pub fn play_slot(slot: u8, source: SlotSource) audio_api.PlaySlotError!void {
    if (slot >= num_slots) return error.InvalidArgs;
    const format = source.format();
    if (!format_supported(format)) return error.UnsupportedFormat;

    const i: usize = slot;
    slots[i].source = source;
    slots[i].format = format;
    slots[i].step_fp = (@as(u64, format.sample_rate) << 32) / device_sample_rate;
    slots[i].phase_fp = 0;
    slots[i].current_left = 0;
    slots[i].current_right = 0;
    slots[i].state = .pending;
}

pub fn stop_slot(slot: u8) void {
    if (slot >= num_slots) return;
    slots[slot].state = .inactive;
}

pub fn set_slot_gain_pan(slot: u8, gain: f32, pan: f32) void {
    if (slot >= num_slots) return;
    slots[slot].gain = gain;
    slots[slot].pan = pan;
}

pub fn is_slot_active(slot: u8) bool {
    if (slot >= num_slots) return false;
    return slots[slot].state != .inactive and slots[slot].state != .finished;
}

fn fill_output_buffer(buf: *c.AudioOutBuffer) void {
    const out: [*]i16 = @ptrCast(@alignCast(buf.buffer.?));

    for (0..samples_per_buf) |frame| {
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

    buf.data_size = output_bytes;
    buf.data_offset = 0;
}

fn advance_sample(slot: *Slot) void {
    slot.phase_fp +%= slot.step_fp;
    while (slot.phase_fp >= fp_one) {
        slot.phase_fp -= fp_one;
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

    read_source_exact(&slot.source, tmp[0..frame_size]) catch return false;

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

fn read_source_exact(source: *SlotSource, dst: []u8) std.Io.Reader.Error!void {
    switch (source.*) {
        .buffer => |buffer| {
            const cursor = buffer.cursor.load(.acquire);
            if (dst.len > buffer.pcm.len -| cursor) return error.EndOfStream;
            @memcpy(dst, buffer.pcm[cursor..][0..dst.len]);
            buffer.cursor.store(cursor + dst.len, .release);
        },
        .stream => |stream| try stream.reader.readSliceAll(dst),
    }
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
