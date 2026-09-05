const std = @import("std");
const surface_api = @import("../surface.zig");
const Surface = @This();

alloc: std.mem.Allocator,

pub fn init(_: *Surface, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) surface_api.InitError!void {}

pub fn deinit(_: *Surface) void {}

pub fn update(_: *Surface) bool {
    return true;
}

pub fn draw(_: *Surface) void {}

pub fn get_width(_: *Surface) u32 {
    return 0;
}

pub fn get_height(_: *Surface) u32 {
    return 0;
}
