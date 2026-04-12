const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const input = if (options.config.gfx == .headless)
    @import("headless/input.zig")
else if (builtin.os.tag == .psp)
    @import("psp/input.zig")
else
    @import("glfw/input.zig");

const Engine = @import("../engine.zig").Engine;

pub const GraphicsAPI = @import("options").@"build.Gfx";

/// Initializes the platform subsystems: graphics and audio.
pub fn init(engine: *Engine, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, resizable: bool) !void {
    try gfx.init(engine.allocator(.render), engine.io, width, height, title, fullscreen, sync, resizable);
    try audio.init(engine.allocator(.audio), engine.io);
}

/// Updates the platform subsystems. Must be called once per frame.
pub fn update(engine: *Engine) void {
    if (!gfx.surface.update()) {
        // Window should close
        engine.running = false;
    }
    audio.update();
}

/// Deinitializes the platform subsystems: graphics and audio.
pub fn deinit() void {
    audio.deinit();
    gfx.deinit();
}
