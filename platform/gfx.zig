const std = @import("std");
const options = @import("options");

const gfx_api = @import("gfx_api.zig");
const surface_iface = @import("surface.zig");
pub const texture_pixels = if (options.config.platform == .psp)
    @import("psp/texture_pixels.zig")
else
    @import("texture_pixels.zig");

pub const Api = switch (options.config.gfx) {
    .default => if (options.config.platform == .nintendo_switch)
        @import("switch/switch_gfx.zig")
    else if (options.config.platform == .nintendo_3ds)
        @import("3ds/gfx.zig")
    else if (options.config.platform == .wasm)
        @import("wasm/webgl_gfx.zig")
    else
        @import("psp/psp_gfx_ge.zig"),
    .opengl => @import("sdl/opengl/opengl_gfx.zig"),
    .vulkan => @import("sdl/vulkan/vulkan_gfx.zig"),
    .webgl => @import("wasm/webgl_gfx.zig"),
    .headless => @import("headless/headless_gfx.zig"),
};

pub const Surface = if (options.config.gfx == .headless)
    @import("headless/surface.zig")
else switch (options.config.platform) {
    .psp => @import("psp/surface.zig"),
    .nintendo_3ds => @import("3ds/surface.zig"),
    .nintendo_switch => @import("switch/surface.zig"),
    .wasm => @import("wasm/surface.zig"),
    else => @import("sdl/surface.zig"),
};

comptime {
    gfx_api.assert_impl(Api);
    surface_iface.assert_impl(Surface);
}

pub const api = Api;
pub var surface: Surface = undefined;
pub var sync: bool = true;
pub var frame_active: bool = false;

pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    width: u32,
    height: u32,
    title: [:0]const u8,
    fullscreen: bool,
    vsync: bool,
    resizable: bool,
) gfx_api.InitError!void {
    sync = vsync;
    surface = .{ .alloc = alloc };
    try surface.init(width, height, title, fullscreen, vsync, resizable);
    errdefer surface.deinit();

    Api.setup(alloc, io);
    try Api.init();
}

pub fn deinit() void {
    Api.deinit();
    surface.deinit();
}

pub fn set_vsync(v: bool) void {
    sync = v;
    Api.set_vsync(v);
}

/// Ensure a backend that borrows CPU mesh memory has finished consuming the
/// previous frame before game code mutates or frees that memory.
pub inline fn wait_for_borrowed_meshes() void {
    if (comptime @hasDecl(Api, "wait_for_borrowed_meshes")) {
        Api.wait_for_borrowed_meshes();
    }
}

pub const has_second_screen = Api.has_second_screen;
pub const switch_second_screen = Api.switch_second_screen;
