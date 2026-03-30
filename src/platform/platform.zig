const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
pub const gfx = @import("gfx.zig");
pub const input = if (options.config.gfx == .headless)
    @import("headless/input.zig")
else if (builtin.os.tag == .psp)
    @import("psp/input.zig")
else
    @import("glfw/input.zig");

const App = @import("../app.zig");

pub const GraphicsAPI = @import("options").@"build.Gfx";

/// Initializes the platform subsystems: graphics and audio.
pub fn init(width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool) !void {
    try gfx.init(width, height, title, fullscreen, sync);
}

/// Updates the platform subsystems. This should be called once per frame.
pub fn update() void {
    if (!gfx.surface.update()) {
        // Window should close
        App.running = false;
    }
}

/// Deinitializes the platform subsystems: graphics and audio.
pub fn deinit() void {
    gfx.deinit();
}
