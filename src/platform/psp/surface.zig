const std = @import("std");
const sdk = @import("pspsdk");
const surface_api = @import("../surface.zig");
const Self = @This();

alloc: std.mem.Allocator,
sync: bool = false,

pub fn init(self: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, sync: bool, _: bool) surface_api.InitError!void {
    self.sync = sync;

    sdk.power.set_clock_frequency(333, 333, 166) catch {};
}

pub fn deinit(_: *Self) void {}

pub fn update(_: *Self) bool {
    return !sdk.extra.utils.isExitRequested();
}

pub fn draw(_: *Self) void {}

pub fn get_width(_: *Self) u32 {
    return sdk.extra.constants.SCREEN_WIDTH;
}

pub fn get_height(_: *Self) u32 {
    return sdk.extra.constants.SCREEN_HEIGHT;
}
