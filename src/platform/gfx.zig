const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const gfx_api = @import("gfx_api.zig");
const surface_iface = @import("surface.zig");

/// Comptime-selected graphics backend module. Backends carry no instance
/// state, so this is a pure namespace alias — calls like
/// `gfx.api.start_frame()` resolve to direct function calls with no
/// indirection.
pub const Api = switch (options.config.gfx) {
    .default => @import("psp/psp_gfx_ge.zig"),
    .opengl => @import("glfw/opengl/opengl_gfx.zig"),
    .vulkan => @import("glfw/vulkan/vulkan_gfx.zig"),
    .headless => @import("headless/headless_gfx.zig"),
};

/// Comptime-selected surface backend type. Surfaces hold real fields
/// (window handle, dimensions), so the storage lives in `surface` below.
pub const Surface = if (options.config.gfx == .headless)
    @import("headless/surface.zig")
else if (builtin.os.tag == .psp)
    @import("psp/surface.zig")
else
    @import("glfw/surface.zig");

comptime {
    gfx_api.assertImpl(Api);
    surface_iface.assertImpl(Surface);
}

pub const api = Api;
pub var surface: Surface = undefined;
pub var sync: bool = true;

/// Initializes the graphics subsystem with the specified parameters.
/// Must be called before any other graphics functions.
pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    width: u32,
    height: u32,
    title: [:0]const u8,
    fullscreen: bool,
    vsync: bool,
    resizable: bool,
) !void {
    sync = vsync;
    surface = .{ .alloc = alloc };
    try surface.init(width, height, title, fullscreen, vsync, resizable);

    Api.setup(alloc, io);
    try Api.init();
}

/// Deinitializes the graphics subsystem and frees all associated resources.
pub fn deinit() void {
    Api.deinit();
    surface.deinit();
}
