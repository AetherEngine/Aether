const std = @import("std");
const sdk = @import("pspsdk");
const ctrl = sdk.ctrl;
const Self = @This();

alloc: std.mem.Allocator,
sync: bool = false,

pub fn init(self: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, sync: bool, _: bool) anyerror!void {
    self.sync = sync;

    _ = ctrl.set_sampling_cycle(0);
    _ = ctrl.set_sampling_mode(.analog);

    // Register the home-button exit callback so pressing Home exits
    // cleanly instead of hanging the game loop.
    sdk.extra.utils.enableHBCB();
}

pub fn deinit(_: *Self) void {}

pub var pad: ctrl.Data = std.mem.zeroes(ctrl.Data);

pub fn update(_: *Self) bool {
    var pad_data: [1]ctrl.Data = undefined;
    _ = ctrl.peek_buffer_positive(&pad_data) catch {};
    pad = pad_data[0];
    return !sdk.extra.utils.isExitRequested();
}

pub fn draw(self: *Self) void {
    if (self.sync) {
        sdk.display.wait_vblank_start() catch {};
    }
}

pub fn get_width(_: *Self) u32 {
    return sdk.extra.constants.SCREEN_WIDTH;
}

pub fn get_height(_: *Self) u32 {
    return sdk.extra.constants.SCREEN_HEIGHT;
}
