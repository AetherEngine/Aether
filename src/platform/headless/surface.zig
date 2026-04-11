const std = @import("std");
const Util = @import("../../util/util.zig");
const Surface = @import("../surface.zig");
const Self = @This();

alloc: std.mem.Allocator,

fn init(_: *anyopaque, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) !void {}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);
    self.alloc.destroy(self);
}

fn update(_: *anyopaque) bool {
    return true;
}

fn draw(_: *anyopaque) void {}

fn get_width(_: *anyopaque) u32 {
    return 0;
}

fn get_height(_: *anyopaque) u32 {
    return 0;
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
