//! Switch surface stub.
//!
//! Switch uses 1280x720 in handheld mode and 1920x1080 in docked mode.

const std = @import("std");
const Self = @This();
const c = @import("../nintendo_c.zig").c;

const HANDHELD_WIDTH = 1280;
const HANDHELD_HEIGHT = 720;
const DOCKED_WIDTH = 1920;
const DOCKED_HEIGHT = 1080;

alloc: std.mem.Allocator,
width: u32 = HANDHELD_WIDTH,
height: u32 = HANDHELD_HEIGHT,

pub fn init(self: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) anyerror!void {
    self.setOperationModeResolution();
}

pub fn deinit(_: *Self) void {}

pub fn update(self: *Self) bool {
    self.setOperationModeResolution();
    return c.appletMainLoop();
}

pub fn draw(_: *Self) void {}

pub fn get_width(self: *Self) u32 {
    return self.width;
}

pub fn get_height(self: *Self) u32 {
    return self.height;
}

fn setOperationModeResolution(self: *Self) void {
    if (c.appletGetOperationMode() == c.AppletOperationMode_Console) {
        self.width = DOCKED_WIDTH;
        self.height = DOCKED_HEIGHT;
    } else {
        self.width = HANDHELD_WIDTH;
        self.height = HANDHELD_HEIGHT;
    }
}
