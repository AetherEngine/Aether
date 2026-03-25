const GraphicsAPI = @import("platform.zig").GraphicsAPI;
const options_gfx: GraphicsAPI = @import("options").config.gfx;

const Surface = @import("surface.zig");
const GFXAPI = @import("gfx_api.zig");

const Util = @import("../util/util.zig");

pub var surface: Surface = undefined;
pub var api: GFXAPI = undefined;

/// Initializes the graphics subsystem with the specified parameters.
/// Must be called before any other graphics functions.
/// Returns an error if initialization fails.
pub fn init(width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool) !void {
    surface = try Surface.make_surface();
    try surface.init(width, height, title, fullscreen, sync);

    api = try GFXAPI.make_api(options_gfx);
    try api.init();
}

/// Deinitializes the graphics subsystem and frees all associated resources.
pub fn deinit() void {
    api.deinit();
    surface.deinit();
}
