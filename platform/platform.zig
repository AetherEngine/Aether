//! Low-level contracts, shared primitives, and selected device services.
const std = @import("std");
const options = @import("options");
const fog_state_3ds = @import("3ds/fog_state.zig");

pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const input = @import("input.zig");
pub const graphics = @import("graphics/graphics.zig");
pub const math = @import("math/math.zig");
pub const util = @import("util/util.zig");
pub const logging = @import("logging.zig");
pub const thread = @import("thread.zig");
pub const paths = @import("paths.zig");
pub const system = @import("system.zig");
pub const network = @import("network.zig");
pub const file_export = @import("file_export.zig");
pub const filesystem = @import("filesystem.zig");
pub const gfx_api = @import("gfx_api.zig");
pub const audio_api = @import("audio_api.zig");
pub const input_api = @import("input_api.zig");
pub const thread_api = @import("thread_api.zig");
pub const surface = @import("surface.zig");

/// Selected native services also exposed by the public engine facade.
pub const Psp = if (options.config.platform == .psp) @import("psp/psp_dialogs.zig") else void;
pub const N3ds = if (options.config.platform == .nintendo_3ds) @import("3ds/app.zig") else void;
pub const Cio = if (options.config.platform == .nintendo_switch) @import("c_io.zig") else void;
pub const CProcessInit = if (options.config.platform == .nintendo_switch) @import("c_process_init.zig") else void;
const app_3ds = if (options.config.platform == .nintendo_3ds) @import("3ds/app.zig") else struct {};
const horizon_3ds = if (options.config.platform == .nintendo_3ds) @import("zitrus").horizon else struct {};

const AppletCallbacks = if (options.config.platform == .nintendo_3ds) struct {
    const ScreenCapture = horizon_3ds.services.GraphicsServerGpu.ScreenCapture;

    fn suspend_for_applet() anyerror!ScreenCapture {
        const capture = if (@hasDecl(gfx.Surface, "suspend_for_applet"))
            try gfx.surface.suspend_for_applet()
        else blk: {
            const app = app_3ds.current_application() orelse return error.NoCurrentApplication;
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

/// Returns false when the window or application requests shutdown.
pub fn update(input_sink: input.EventSink) bool {
    if (options.config.platform == .nintendo_3ds and !app_3ds.update(AppletCallbacks.suspend_for_applet, AppletCallbacks.resume_from_applet)) {
        return false;
    }
    if (!gfx.surface.update()) return false;
    if (@hasDecl(gfx.Surface, "take_docked_mode_entered") and @hasDecl(input.api, "handle_docked_mode_entered")) {
        if (gfx.surface.take_docked_mode_entered()) {
            input.api.handle_docked_mode_entered(input_sink);
        }
    }
    return true;
}

pub fn yield_thread() void {
    if (options.config.platform == .nintendo_3ds) horizon_3ds.sleepThread(0);
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(system);
    std.testing.refAllDecls(network);
    std.testing.refAllDecls(file_export);
    // Core no longer brings these nested files into Platform's test root.
    std.testing.refAllDecls(input_api.frame);
    std.testing.refAllDecls(gfx.texture_pixels);
    std.testing.refAllDecls(fog_state_3ds);
}
