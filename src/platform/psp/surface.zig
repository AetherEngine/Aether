const std = @import("std");
const Util = @import("../../util/util.zig");
const Surface = @import("../surface.zig");
const sdk = @import("pspsdk");
const ctrl = sdk.ctrl;
const Self = @This();

alloc: std.mem.Allocator,
sync: bool = false,

fn init(ctx: *anyopaque, _: u32, _: u32, _: [:0]const u8, _: bool, sync: bool, _: bool) !void {
    const self = Util.ctx_to_self(Self, ctx);
    self.sync = sync;

    _ = ctrl.set_sampling_cycle(0);
    _ = ctrl.set_sampling_mode(.analog);
}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);
    self.alloc.destroy(self);
}

pub var pad: ctrl.Data = std.mem.zeroes(ctrl.Data);

fn update(_: *anyopaque) bool {
    var pad_data: [1]ctrl.Data = undefined;
    _ = ctrl.peek_buffer_positive(&pad_data) catch {};
    pad = pad_data[0];
    return true;
}

fn draw(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);
    if (self.sync) {
        sdk.display.wait_vblank_start() catch {};
    }
}

fn get_width(_: *anyopaque) u32 {
    return sdk.extra.constants.SCREEN_WIDTH;
}

fn get_height(_: *anyopaque) u32 {
    return sdk.extra.constants.SCREEN_HEIGHT;
}

pub fn surface(self: *Self) Surface {
    return Surface{ .ptr = self, .tab = &.{
        .init = init,
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .get_width = get_width,
        .get_height = get_height,
    } };
}
