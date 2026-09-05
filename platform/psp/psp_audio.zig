//! Mixes slots into one stereo PSP hardware channel on a dedicated thread.

const std = @import("std");
const sdk = @import("pspsdk");
const audio_api = @import("../audio_api.zig");
const SlotSource = audio_api.SlotSource;
const PcmFormat = audio_api.PcmFormat;

const num_slots: usize = 8;
const samples_per_buf: usize = 1024;
const read_buf_size: usize = samples_per_buf * 2 * 2 * 8;
const output_buf_bytes: usize = samples_per_buf * 2 * 2;
const psp_volume_max: i32 = 0x8000;

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
    source: SlotSource = undefined,
    read_buf: [read_buf_size]u8 = undefined,
};

var slots: [num_slots]Slot = @splat(.{});

var hw_channel: i32 = -1;
var thread_id: sdk.SceUID = -1;
var running: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

// PSP DMA requires 64-byte alignment.
var output_bufs: [2][output_buf_bytes]u8 align(64) = @splat(@splat(0));

pub fn init(_: std.mem.Allocator, _: std.Io) audio_api.InitError!void {
    hw_channel = sdk.audio.ch_reserve(sdk.audio.next_channel, @intCast(samples_per_buf), .stereo) catch
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
    slots = @splat(.{});
}

pub fn update() void {}

pub fn max_voices() u32 {
    return num_slots;
}

pub fn play_slot(slot: u8, source: SlotSource) audio_api.PlaySlotError!void {
    if (slot >= num_slots) return error.InvalidArgs;
    slots[slot].source = source;
    slots[slot].state.store(@intFromEnum(SlotState.pending), .release);
}

pub fn stop_slot(slot: u8) void {
    if (slot >= num_slots) return;
    slots[slot].state.store(@intFromEnum(SlotState.inactive), .release);
}

pub fn set_slot_gain_pan(slot: u8, gain: f32, pan: f32) void {
    if (slot >= num_slots) return;
    slots[slot].gain.store(@bitCast(gain), .release);
    slots[slot].pan.store(@bitCast(pan), .release);
}

pub fn is_slot_active(slot: u8) bool {
    if (slot >= num_slots) return false;
    const state: SlotState = @enumFromInt(slots[slot].state.load(.acquire));
    return state != .inactive and state != .finished;
}

fn audio_thread_fn(_: usize, _: ?*anyopaque) callconv(.c) c_int {
    var cur: u1 = 0;

    while (running.load(.acquire) != 0) {
        fill_buffer(&output_bufs[cur]);

        sdk.audio.output_panned_blocking(
            hw_channel,
            psp_volume_max,
            psp_volume_max,
            @ptrCast(&output_bufs[cur]),
        ) catch {};

        cur ^= 1;
    }

    return 0;
}

fn fill_buffer(buf: *[output_buf_bytes]u8) void {
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

        const fmt = slot.source.format();
        const bytes_needed: usize = samples_per_buf * fmt.frame_size();

        if (bytes_needed > read_buf_size) {
            slot.state.store(@intFromEnum(SlotState.finished), .release);
            continue;
        }

        const read_buf = slot.read_buf[0..bytes_needed];

        if (!read_source(&slot.source, read_buf)) {
            slot.state.store(@intFromEnum(SlotState.finished), .release);
            continue;
        }

        mix_into_i16(out, read_buf, fmt, left_vol, right_vol);
    }
}

fn read_source(source: *SlotSource, dst: []u8) bool {
    switch (source.*) {
        .buffer => |buffer| {
            const cursor = buffer.cursor.load(.acquire);
            if (cursor >= buffer.pcm.len) return false;
            const remaining = buffer.pcm.len - cursor;
            const n = @min(dst.len, remaining);
            @memcpy(dst[0..n], buffer.pcm[cursor..][0..n]);
            if (n < dst.len) @memset(dst[n..], 0);
            buffer.cursor.store(cursor + n, .release);
            return true;
        },
        .stream => |stream| {
            stream.reader.readSliceAll(dst) catch return false;
            return true;
        },
    }
}

fn mix_into_i16(
    out: [*]i16,
    buf: []const u8,
    fmt: PcmFormat,
    left_vol: i32,
    right_vol: i32,
) void {
    if (fmt.bit_depth != 16) return;

    if (fmt.channels == 1) {
        for (0..samples_per_buf) |f| {
            const s: i32 = std.mem.readInt(i16, buf[f * 2 ..][0..2], .little);
            out[f * 2] +|= @intCast((s * left_vol) >> 15);
            out[f * 2 + 1] +|= @intCast((s * right_vol) >> 15);
        }
    } else {
        for (0..samples_per_buf) |f| {
            const l: i32 = std.mem.readInt(i16, buf[f * 4 ..][0..2], .little);
            const r: i32 = std.mem.readInt(i16, buf[f * 4 + 2 ..][0..2], .little);
            out[f * 2] +|= @intCast((l * left_vol) >> 15);
            out[f * 2 + 1] +|= @intCast((r * right_vol) >> 15);
        }
    }
}
