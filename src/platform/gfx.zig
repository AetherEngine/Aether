const std = @import("std");
const GraphicsAPI = @import("platform.zig").GraphicsAPI;
const options_gfx: GraphicsAPI = @import("options").config.gfx;

const Surface = @import("surface.zig");
const GFXAPI = @import("gfx_api.zig");

pub var surface: Surface = undefined;
pub var api: GFXAPI = undefined;
pub var sync: bool = true;

/// Initializes the graphics subsystem with the specified parameters.
/// Must be called before any other graphics functions.
/// Returns an error if initialization fails.
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
    surface = try Surface.make_surface(alloc);
    try surface.init(width, height, title, fullscreen, vsync, resizable);

    api = try GFXAPI.make_api(alloc, io, options_gfx);
    try api.init();
}

/// Deinitializes the graphics subsystem and frees all associated resources.
pub fn deinit() void {
    api.deinit();
    surface.deinit();
}
