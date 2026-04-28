//! Switch audio backend stub.
//!
//! Empty slot-based PCM output that satisfies `audio_api.Interface`.
//! Real bring-up will route through libnx's `audren` (the high-level
//! audio renderer) or `audout` for raw PCM. 24 voices matches what
//! audren exposes by default — bump if a downstream game needs more.

const std = @import("std");
const Stream = @import("../../audio/stream.zig").Stream;

var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    audio_alloc = alloc;
    audio_io = io;
}

pub fn init() anyerror!void {}
pub fn deinit() void {}
pub fn update() void {}

pub fn max_voices() u32 {
    return 24;
}

pub fn play_slot(_: u8, _: Stream) anyerror!void {}

pub fn stop_slot(_: u8) void {}

pub fn set_slot_gain_pan(_: u8, _: f32, _: f32) void {}

pub fn is_slot_active(_: u8) bool {
    return false;
}
