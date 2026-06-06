//! Switch surface stub.
//!
//! Switch's framebuffer is 1280x720 in handheld mode and 1920x1080
//! docked. We advertise 1280x720 so the engine has a sane default;
//! a real backend will query `appletGetOperationMode` and resize on
//! dock transitions.

const std = @import("std");
const Self = @This();
const c = @import("../nintendo_c.zig").c;

alloc: std.mem.Allocator,

pub fn init(_: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) anyerror!void {}

pub fn deinit(_: *Self) void {}

pub fn update(_: *Self) bool {
    return c.appletMainLoop();
}

pub fn draw(_: *Self) void {}

pub fn get_width(_: *Self) u32 {
    return 1280;
}

pub fn get_height(_: *Self) u32 {
    return 720;
}
