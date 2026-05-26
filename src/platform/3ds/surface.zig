//! 3DS surface stub.
//!
//! Top screen of an O3DS is 400x240; bottom touch screen is 320x240. The
//! real backend will likely advertise the top screen here and expose the
//! bottom one separately.

const std = @import("std");
const Self = @This();

extern fn aptMainLoop() bool;

alloc: std.mem.Allocator,

pub fn init(_: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) anyerror!void {}

pub fn deinit(_: *Self) void {}

pub fn update(_: *Self) bool {
    return aptMainLoop();
}

pub fn draw(_: *Self) void {}

pub fn get_width(_: *Self) u32 {
    return 400;
}

pub fn get_height(_: *Self) u32 {
    return 240;
}
