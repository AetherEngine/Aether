//! Switch surface stub.
//!
//! Switch uses 1280x720 in handheld mode and 1920x1080 in docked mode.

const std = @import("std");
const surface_api = @import("../surface.zig");
const Surface = @This();
const c = @import("c.zig").switch_c;

const handheld_width = 1280;
const handheld_height = 720;
const docked_width = 1920;
const docked_height = 1080;

alloc: std.mem.Allocator,
width: u32 = handheld_width,
height: u32 = handheld_height,
operation_mode: c.AppletOperationMode = c.AppletOperationMode_Handheld,
docked_mode_entered: bool = false,

pub fn init(self: *Surface, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) surface_api.InitError!void {
    self.operation_mode = c.appletGetOperationMode();
    self.set_operation_mode_resolution(self.operation_mode);
    self.docked_mode_entered = false;
}

pub fn deinit(_: *Surface) void {}

pub fn update(self: *Surface) bool {
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

pub fn draw(_: *Surface) void {}

pub fn get_width(self: *Surface) u32 {
    return self.width;
}

pub fn get_height(self: *Surface) u32 {
    return self.height;
}

pub fn take_docked_mode_entered(self: *Surface) bool {
    const entered = self.docked_mode_entered;
    self.docked_mode_entered = false;
    return entered;
}

fn set_operation_mode_resolution(self: *Surface, mode: c.AppletOperationMode) void {
    if (mode == c.AppletOperationMode_Console) {
        self.width = docked_width;
        self.height = docked_height;
    } else {
        self.width = handheld_width;
        self.height = handheld_height;
    }
}
