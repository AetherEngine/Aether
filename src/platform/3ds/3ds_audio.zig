//! 3DS audio backend stub.
//!
//! Empty slot-based PCM output that satisfies `audio_api.Interface`.
//! Real bring-up will route through libctru's NDSP (or CSND on older
//! firmwares). 24 voices is what NDSP exposes on retail hardware.

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
