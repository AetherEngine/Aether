//! Switch surface stub.
//!
//! Switch uses 1280x720 in handheld mode and 1920x1080 in docked mode.

const std = @import("std");
const surface_api = @import("../surface.zig");
const Self = @This();
const c = @import("../nintendo_c.zig").switch_c;

const HANDHELD_WIDTH = 1280;
const HANDHELD_HEIGHT = 720;
const DOCKED_WIDTH = 1920;
const DOCKED_HEIGHT = 1080;

alloc: std.mem.Allocator,
width: u32 = HANDHELD_WIDTH,
height: u32 = HANDHELD_HEIGHT,
operation_mode: c.AppletOperationMode = c.AppletOperationMode_Handheld,
docked_mode_entered: bool = false,

pub fn init(self: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) surface_api.InitError!void {
    self.operation_mode = c.appletGetOperationMode();
    self.set_operation_mode_resolution(self.operation_mode);
    self.docked_mode_entered = false;
}

pub fn deinit(_: *Self) void {}

pub fn update(self: *Self) bool {
    const running = c.appletMainLoop();
    const mode = c.appletGetOperationMode();
    if (mode != self.operation_mode) {
        const entered_docked_mode = self.operation_mode != c.AppletOperationMode_Console and mode == c.AppletOperationMode_Console;
        self.operation_mode = mode;
        self.docked_mode_entered = self.docked_mode_entered or entered_docked_mode;
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

pub fn take_docked_mode_entered(self: *Self) bool {
    const entered = self.docked_mode_entered;
    self.docked_mode_entered = false;
    return entered;
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
