const std = @import("std");
const options = @import("options");

pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const input = @import("input.zig");
const app_3ds = if (options.config.platform == .nintendo_3ds) @import("3ds/app.zig") else struct {};
const horizon_3ds = if (options.config.platform == .nintendo_3ds) @import("zitrus").horizon else struct {};

const Engine = @import("../engine.zig").Engine;
const gfx_api = @import("gfx_api.zig");
const audio_api = @import("audio_api.zig");
const input_api = @import("input_api.zig");

pub const GraphicsAPI = @import("options").@"build.Gfx";

pub const InitError = error{
    GfxInitOutOfMemory,
    AudioInitOutOfMemory,
    InputInitOutOfMemory,
} || gfx_api.InitError || audio_api.InitError || input_api.InitError;

const AppletCallbacks = if (options.config.platform == .nintendo_3ds) struct {
    const ScreenCapture = horizon_3ds.services.GraphicsServerGpu.ScreenCapture;

    fn suspend_for_applet() anyerror!ScreenCapture {
        const capture = if (@hasDecl(gfx.Surface, "suspend_for_applet"))
            try gfx.surface.suspend_for_applet()
        else blk: {
            const app = app_3ds.currentApplication() orelse return error.NoCurrentApplication;
            break :blk try app.gsp.sendImportDisplayCaptureInfo();
        };
        audio.Api.suspend_for_applet();
        return capture;
    }

    fn resume_from_applet() void {
        if (@hasDecl(gfx.Surface, "resume_from_applet")) gfx.surface.resume_from_applet();
        audio.Api.resume_from_applet();
    }
} else struct {};

/// Initializes the platform subsystems: graphics, audio, then input.
/// Order matters: input subscribes to surface callbacks created by gfx.
pub fn init(engine: *Engine, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, resizable: bool) InitError!void {
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
    if (options.config.platform == .nintendo_3ds and !app_3ds.update(AppletCallbacks.suspend_for_applet, AppletCallbacks.resume_from_applet)) {
        engine.running = false;
        return;
    }

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
    if (options.config.platform == .nintendo_3ds) {
        horizon_3ds.sleepThread(0);
    }
}

/// Deinitializes the platform subsystems in reverse order.
pub fn deinit() void {
    input.deinit();
    audio.deinit();
    gfx.deinit();
}
