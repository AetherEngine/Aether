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
operation_mode: c.AppletOperationMode = c.AppletOperationMode_Handheld,
operation_mode_changed: bool = false,

pub fn init(self: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) anyerror!void {
    self.operation_mode = c.appletGetOperationMode();
    self.set_operation_mode_resolution(self.operation_mode);
    self.operation_mode_changed = false;
}

pub fn deinit(_: *Self) void {}

pub fn update(self: *Self) bool {
    const running = c.appletMainLoop();
    const mode = c.appletGetOperationMode();
    if (mode != self.operation_mode) {
        self.operation_mode = mode;
        self.operation_mode_changed = true;
    }
    self.set_operation_mode_resolution(mode);
    return running;
}

pub fn draw(_: *Self) void {}

pub fn get_width(self: *Self) u32 {
    return self.width;
}

pub fn get_height(self: *Self) u32 {
    return self.height;
}

pub fn take_operation_mode_changed(self: *Self) bool {
    const changed = self.operation_mode_changed;
    self.operation_mode_changed = false;
    return changed;
}

fn set_operation_mode_resolution(self: *Self, mode: c.AppletOperationMode) void {
    if (mode == c.AppletOperationMode_Console) {
        self.width = DOCKED_WIDTH;
        self.height = DOCKED_HEIGHT;
    } else {
        self.width = HANDHELD_WIDTH;
        self.height = HANDHELD_HEIGHT;
    }
}
