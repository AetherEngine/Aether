//! 3DS audio backend -- NDSP hardware voices.
//!
//! Each Aether mixer slot maps to one NDSP channel. The game thread refills
//! double-buffered linear-memory wave buffers from the Stream reader in
//! `update`; NDSP handles sample-rate conversion and channel mixing.

const std = @import("std");
const surface = @import("surface.zig");
const Stream = @import("../../audio/stream.zig").Stream;
const PcmFormat = @import("../../audio/stream.zig").PcmFormat;

const NUM_SLOTS: usize = 24;
const BUFFERS_PER_SLOT: usize = 2;
const SAMPLES_PER_BUF: usize = 4096;
const MAX_CHANNELS: usize = 2;
const MAX_BYTES_PER_SAMPLE: usize = 2;
const MAX_BYTES_PER_BUF: usize = SAMPLES_PER_BUF * MAX_CHANNELS * MAX_BYTES_PER_SAMPLE;
const TOTAL_AUDIO_BYTES: usize = NUM_SLOTS * BUFFERS_PER_SLOT * MAX_BYTES_PER_BUF;

const NDSP_OUTPUT_STEREO: c_int = 1;
const NDSP_INTERP_LINEAR: c_int = 1;
const NDSP_FORMAT_MONO_PCM16: u16 = 5;
const NDSP_FORMAT_STEREO_PCM16: u16 = 6;
const NDSP_WBUF_DONE: u8 = 3;

const Result = c_int;

const NdspAdpcmData = extern struct {
    index: u16,
    history0: i16,
    history1: i16,
};

const NdspWaveBuf = extern struct {
    data_vaddr: ?*const anyopaque,
    nsamples: u32,
    adpcm_data: ?*NdspAdpcmData,
    offset: u32,
    looping: bool,
    status: u8,
    sequence_id: u16,
    next: ?*NdspWaveBuf,
};

extern fn ndspInit() Result;
extern fn ndspExit() void;
extern fn ndspSetOutputMode(mode: c_int) void;
extern fn ndspChnReset(id: c_int) void;
extern fn ndspChnSetInterp(id: c_int, interp: c_int) void;
extern fn ndspChnSetRate(id: c_int, rate: f32) void;
extern fn ndspChnSetFormat(id: c_int, format: u16) void;
extern fn ndspChnSetMix(id: c_int, mix: *[12]f32) void;
extern fn ndspChnWaveBufClear(id: c_int) void;
extern fn ndspChnWaveBufAdd(id: c_int, buf: *NdspWaveBuf) void;
extern fn DSP_FlushDataCache(address: *const anyopaque, size: u32) Result;
extern fn linearAlloc(size: usize) ?*anyopaque;
extern fn linearFree(mem: ?*anyopaque) void;

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
    wave_bufs: [BUFFERS_PER_SLOT]NdspWaveBuf = undefined,
};

var slots: [NUM_SLOTS]Slot = init_slots();
var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;
var audio_data: ?[*]u8 = null;

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

    audio_data = @ptrCast(linearAlloc(TOTAL_AUDIO_BYTES) orelse return error.AudioLinearAllocFailed);

    if (ndspInit() != 0) {
        linearFree(audio_data);
        audio_data = null;
        return error.NdspInitFailed;
    }

    ndspSetOutputMode(NDSP_OUTPUT_STEREO);

    for (0..NUM_SLOTS) |i| {
        ndspChnReset(@intCast(i));
        slots[i] = .{};
        init_wave_bufs(i);
    }
}

pub fn deinit() void {
    if (surface.is_system_closing()) {
        slots = init_slots();
        audio_data = null;
        return;
    }

    for (0..NUM_SLOTS) |i| {
        ndspChnWaveBufClear(@intCast(i));
        ndspChnReset(@intCast(i));
        slots[i].state = .inactive;
    }

    ndspExit();

    if (audio_data) |data| {
        linearFree(data);
        audio_data = null;
    }
}

pub fn update() void {
    if (audio_data == null) return;

    for (&slots, 0..) |*slot, i| {
        switch (slot.state) {
            .inactive, .finished => {},
            .pending => start_slot(slot, i) catch {
                slot.state = .finished;
            },
            .active => refill_done_buffers(slot, i),
        }
    }
}

pub fn max_voices() u32 {
    return NUM_SLOTS;
}

pub fn play_slot(slot: u8, stream: Stream) anyerror!void {
    if (slot >= NUM_SLOTS) return error.InvalidArgs;
    if (!format_supported(stream.format)) return error.UnsupportedFormat;

    const i: usize = slot;
    ndspChnWaveBufClear(slot);
    slots[i].stream = stream;
    slots[i].format = stream.format;
    slots[i].state = .pending;
}

pub fn stop_slot(slot: u8) void {
    if (slot >= NUM_SLOTS) return;
    ndspChnWaveBufClear(slot);
    slots[slot].state = .inactive;
}

pub fn set_slot_gain_pan(slot: u8, gain: f32, pan: f32) void {
    if (slot >= NUM_SLOTS) return;
    slots[slot].gain = gain;
    slots[slot].pan = pan;
    if (slots[slot].state == .active) apply_mix(slot, &slots[slot]);
}

pub fn is_slot_active(slot: u8) bool {
    if (slot >= NUM_SLOTS) return false;
    return slots[slot].state != .inactive and slots[slot].state != .finished;
}

fn init_wave_bufs(slot_index: usize) void {
    const base = audio_data.?;
    const slot_base = slot_index * BUFFERS_PER_SLOT * MAX_BYTES_PER_BUF;

    for (&slots[slot_index].wave_bufs, 0..) |*buf, b| {
        buf.* = .{
            .data_vaddr = @ptrCast(base + slot_base + b * MAX_BYTES_PER_BUF),
            .nsamples = SAMPLES_PER_BUF,
            .adpcm_data = null,
            .offset = 0,
            .looping = false,
            .status = NDSP_WBUF_DONE,
            .sequence_id = 0,
            .next = null,
        };
    }
}

fn start_slot(slot: *Slot, slot_index: usize) !void {
    const id: c_int = @intCast(slot_index);

    ndspChnWaveBufClear(id);
    ndspChnReset(id);
    ndspChnSetInterp(id, NDSP_INTERP_LINEAR);
    ndspChnSetRate(id, @floatFromInt(slot.format.sample_rate));
    ndspChnSetFormat(id, if (slot.format.channels == 1) NDSP_FORMAT_MONO_PCM16 else NDSP_FORMAT_STEREO_PCM16);
    apply_mix(@intCast(slot_index), slot);

    var queued: bool = false;
    for (&slot.wave_bufs) |*buf| {
        if (fill_wave_buf(slot, buf)) {
            ndspChnWaveBufAdd(id, buf);
            queued = true;
        } else break;
    }

    slot.state = if (queued) .active else .finished;
}

fn refill_done_buffers(slot: *Slot, slot_index: usize) void {
    const id: c_int = @intCast(slot_index);

    for (&slot.wave_bufs) |*buf| {
        if (buf.status != NDSP_WBUF_DONE) continue;
        if (!fill_wave_buf(slot, buf)) {
            slot.state = .finished;
            return;
        }
        ndspChnWaveBufAdd(id, buf);
    }
}

fn fill_wave_buf(slot: *Slot, buf: *NdspWaveBuf) bool {
    const byte_count = SAMPLES_PER_BUF * slot.format.frame_size();
    if (byte_count > MAX_BYTES_PER_BUF) return false;

    const raw: [*]u8 = @ptrCast(@constCast(buf.data_vaddr.?));
    const dst = raw[0..byte_count];

    slot.stream.reader.readSliceAll(dst) catch return false;
    _ = DSP_FlushDataCache(buf.data_vaddr.?, @intCast(byte_count));

    buf.nsamples = SAMPLES_PER_BUF;
    buf.offset = 0;
    buf.looping = false;
    buf.status = NDSP_WBUF_DONE;
    buf.next = null;
    return true;
}

fn apply_mix(slot: u8, s: *const Slot) void {
    const left = s.gain * std.math.clamp(1.0 - s.pan, 0.0, 1.0);
    const right = s.gain * std.math.clamp(1.0 + s.pan, 0.0, 1.0);
    var mix: [12]f32 = @splat(0);
    mix[0] = std.math.clamp(left, 0.0, 1.0);
    mix[1] = std.math.clamp(right, 0.0, 1.0);
    ndspChnSetMix(slot, &mix);
}

fn format_supported(fmt: PcmFormat) bool {
    return fmt.bit_depth == 16 and (fmt.channels == 1 or fmt.channels == 2);
}
