const options = @import("options");

pub const gfx = @import("gfx.zig");
pub const audio = @import("audio.zig");
pub const input = @import("input.zig");
const app_3ds = if (options.config.platform == .nintendo_3ds) @import("3ds/app.zig") else struct {};
const horizon_3ds = if (options.config.platform == .nintendo_3ds) @import("zitrus").horizon else struct {};

const InputSystem = @import("../core/input/input.zig").InputSystem;

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
pub fn update(input_system: *InputSystem) bool {
    if (options.config.platform == .nintendo_3ds and !app_3ds.update(AppletCallbacks.suspend_for_applet, AppletCallbacks.resume_from_applet)) {
        return false;
    }
    if (!gfx.surface.update()) return false;
    if (@hasDecl(gfx.Surface, "take_docked_mode_entered") and @hasDecl(input.api, "handle_docked_mode_entered")) {
        if (gfx.surface.take_docked_mode_entered()) {
            input.api.handle_docked_mode_entered(input_system);
        }
    }
    return true;
}

pub fn yield_thread() void {
    if (options.config.platform == .nintendo_3ds) horizon_3ds.sleepThread(0);
}
