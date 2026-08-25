const std = @import("std");
const surface_api = @import("../surface.zig");
const Surface = @This();

extern "aether_host" fn aether_canvas_width() u32;
extern "aether_host" fn aether_canvas_height() u32;
extern "aether_host" fn aether_surface_init(width: u32, height: u32, title_ptr: [*]const u8, title_len: usize, resizable: bool) void;
extern "aether_host" fn aether_surface_present() void;

alloc: std.mem.Allocator,

pub fn init(_: *Surface, width: u32, height: u32, title: [:0]const u8, _: bool, _: bool, resizable: bool) surface_api.InitError!void {
    aether_surface_init(width, height, title.ptr, title.len, resizable);
}

pub fn deinit(_: *Surface) void {}

pub fn update(_: *Surface) bool {
    return true;
}

pub fn draw(_: *Surface) void {
    aether_surface_present();
}

pub fn get_width(_: *Surface) u32 {
    return aether_canvas_width();
}

pub fn get_height(_: *Surface) u32 {
    return aether_canvas_height();
}
