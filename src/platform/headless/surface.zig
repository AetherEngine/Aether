const std = @import("std");
const Self = @This();

alloc: std.mem.Allocator,

pub fn init(_: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, _: bool, _: bool) anyerror!void {}

pub fn deinit(_: *Self) void {}

pub fn update(_: *Self) bool {
    return true;
}

pub fn draw(_: *Self) void {}

pub fn get_width(_: *Self) u32 {
    return 0;
}

pub fn get_height(_: *Self) u32 {
    return 0;
}
