//! 3DS surface stub.
//!
//! Top screen of an O3DS is 400x240; bottom touch screen is 320x240. The
//! real backend will likely advertise the top screen here and expose the
//! bottom one separately.

const std = @import("std");
const Self = @This();

extern fn aptMainLoop() bool;
extern fn aptShouldClose() bool;

var system_closing = false;

alloc: std.mem.Allocator,

pub fn init(_: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) anyerror!void {
    system_closing = false;
}

pub fn deinit(_: *Self) void {}

pub fn update(_: *Self) bool {
    if (system_closing) return false;

    const keep_running = aptMainLoop();
    if (!keep_running or aptShouldClose()) {
        system_closing = true;
        return false;
    }
    return true;
}

pub fn draw(_: *Self) void {}

pub fn is_system_closing() bool {
    return system_closing;
}

pub fn get_width(_: *Self) u32 {
    return 400;
}

pub fn get_height(_: *Self) u32 {
    return 240;
}
