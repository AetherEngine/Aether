const std = @import("std");
const audio_api = @import("../audio_api.zig");
const SlotSource = @import("../../audio/stream.zig").SlotSource;

const MAX_SLOTS = 32;

extern "aether_host" fn aether_audio_init(sample_rate: u32, max_slots: u32) void;
extern "aether_host" fn aether_audio_deinit() void;
extern "aether_host" fn aether_audio_update() void;
extern "aether_host" fn aether_audio_play_slot(slot: u32, ptr: [*]const u8, len: usize, sample_rate: u32, channels: u32, bit_depth: u32) bool;
extern "aether_host" fn aether_audio_stop_slot(slot: u32) void;
extern "aether_host" fn aether_audio_set_slot_gain_pan(slot: u32, gain: f32, pan: f32) void;
extern "aether_host" fn aether_audio_is_slot_active(slot: u32) bool;

var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    audio_alloc = alloc;
    audio_io = io;
    _ = audio_io;
}

pub fn init() audio_api.InitError!void {
    aether_audio_init(48_000, MAX_SLOTS);
}

pub fn deinit() void {
    aether_audio_deinit();
}

pub fn update() void {
    aether_audio_update();
}

pub fn max_voices() u32 {
    return MAX_SLOTS;
}

pub fn play_slot(slot: u8, source: SlotSource) audio_api.PlaySlotError!void {
    if (slot >= MAX_SLOTS) return;

    switch (source) {
        .buffer => |buffer| {
            if (!aether_audio_play_slot(slot, buffer.pcm.ptr, buffer.pcm.len, buffer.format.sample_rate, buffer.format.channels, buffer.format.bit_depth)) {
                return error.AudioHostRejectedStream;
            }
            buffer.cursor.store(buffer.pcm.len, .release);
        },
        .stream => |stream| {
            const len = stream.byte_length orelse return error.AudioHostRejectedStream;
            const data = std.heap.wasm_allocator.alloc(u8, @intCast(len)) catch return error.OutOfMemory;
            defer std.heap.wasm_allocator.free(data);
            stream.reader.readSliceAll(data) catch return error.AudioHostRejectedStream;

            if (!aether_audio_play_slot(slot, data.ptr, data.len, stream.format.sample_rate, stream.format.channels, stream.format.bit_depth)) {
                return error.AudioHostRejectedStream;
            }
        },
    }
}

pub fn stop_slot(slot: u8) void {
    if (slot >= MAX_SLOTS) return;
    aether_audio_stop_slot(slot);
}

pub fn set_slot_gain_pan(slot: u8, gain: f32, pan: f32) void {
    if (slot >= MAX_SLOTS) return;
    aether_audio_set_slot_gain_pan(slot, gain, pan);
}

pub fn is_slot_active(slot: u8) bool {
    if (slot >= MAX_SLOTS) return false;
    return aether_audio_is_slot_active(slot);
}
