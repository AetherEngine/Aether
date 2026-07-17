const std = @import("std");
const audio_api = @import("../audio_api.zig");
const SlotSource = @import("../../audio/stream.zig").SlotSource;

var audio_alloc: std.mem.Allocator = undefined;
var audio_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    audio_alloc = alloc;
    audio_io = io;
}

pub fn init() audio_api.InitError!void {}
pub fn deinit() void {}
pub fn update() void {}
pub fn suspend_for_applet() void {}
pub fn resume_from_applet() void {}

pub fn max_voices() u32 {
    return 32;
}

pub fn play_slot(_: u8, _: SlotSource) audio_api.PlaySlotError!void {}

pub fn stop_slot(_: u8) void {}

pub fn set_slot_gain_pan(_: u8, _: f32, _: f32) void {}

pub fn is_slot_active(_: u8) bool {
    return false;
}
