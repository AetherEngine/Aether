const std = @import("std");
const Self = @This();

alloc: std.mem.Allocator,
width: u32 = 400,
height: u32 = 240,

pub fn init(self: *Self, width: u32, height: u32, _: [:0]const u8, _: bool, _: bool, _: bool) anyerror!void {
    self.width = if (width == 0) 400 else width;
    self.height = if (height == 0) 240 else height;
}

pub fn deinit(_: *Self) void {}

pub fn update(_: *Self) bool {
    return true;
}

pub fn draw(_: *Self) void {}

pub fn get_width(self: *Self) u32 {
    return self.width;
}

pub fn get_height(self: *Self) u32 {
    return self.height;
}
