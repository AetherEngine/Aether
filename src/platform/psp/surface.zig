const Util = @import("../../util/util.zig");
const Surface = @import("../surface.zig");
const Self = @This();

width: u32,
height: u32,

fn init(ctx: *anyopaque, width: u32, height: u32, _: [:0]const u8, _: bool, _: bool) !void {
    const self = Util.ctx_to_self(Self, ctx);
    self.width = width;
    self.height = height;
}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);
    Util.allocator(.render).destroy(self);
}

fn update(_: *anyopaque) bool {
    return true;
}

fn draw(_: *anyopaque) void {}

fn get_width(ctx: *anyopaque) u32 {
    const self = Util.ctx_to_self(Self, ctx);
    return self.width;
}

fn get_height(ctx: *anyopaque) u32 {
    const self = Util.ctx_to_self(Self, ctx);
    return self.height;
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
