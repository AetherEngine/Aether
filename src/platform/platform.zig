const std = @import("std");

pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const input = @import("input.zig");

const Engine = @import("../engine.zig").Engine;

pub const GraphicsAPI = @import("options").@"build.Gfx";

/// Initializes the platform subsystems: graphics, audio, then input.
/// Order matters: input subscribes to surface callbacks created by gfx.
pub fn init(engine: *Engine, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, resizable: bool) !void {
    gfx.init(engine.allocator(.render), engine.io, width, height, title, fullscreen, sync, resizable) catch |err| switch (err) {
        error.OutOfMemory => return error.GfxInitOutOfMemory,
        else => return err,
    };
    audio.init(engine.allocator(.audio), engine.io) catch |err| switch (err) {
        error.OutOfMemory => return error.AudioInitOutOfMemory,
        else => return err,
    };
    input.init(engine.allocator(.game), engine.io) catch |err| switch (err) {
        error.OutOfMemory => return error.InputInitOutOfMemory,
        else => return err,
    };
}

/// Updates the platform subsystems. Must be called once per frame.
pub fn update(engine: *Engine) void {
    if (!gfx.surface.update()) {
        // Window should close
        engine.running = false;
        return;
    }
    if (@hasDecl(gfx.Surface, "take_operation_mode_changed") and @hasDecl(input.Api, "handle_operation_mode_changed")) {
        if (gfx.surface.take_operation_mode_changed()) {
            input.Api.handle_operation_mode_changed();
        }
    }
    audio.update();
}

/// Deinitializes the platform subsystems in reverse order.
pub fn deinit() void {
    input.deinit();
    audio.deinit();
    gfx.deinit();
}
