const std = @import("std");
const builtin = @import("builtin");
const surface_api = @import("../surface.zig");
const Util = @import("../../util/util.zig");
const sdl3 = @import("sdl3");

const Self = @This();
const api = @import("options").config.gfx;

const SDL_VIDEO_FLAGS = sdl3.InitFlags{ .video = true, .gamepad = true };

alloc: std.mem.Allocator,
window: sdl3.video.Window = undefined,
gl_context: ?sdl3.video.gl.Context = null,
width: c_int = 0,
height: c_int = 0,
should_quit: bool = false,

pub var on_resize: ?*const fn () void = null;

pub fn init(self: *Self, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, resizable: bool) surface_api.InitError!void {
    sdl3.init(SDL_VIDEO_FLAGS) catch return error.SurfaceInitFailed;

    const version = sdl3.c.SDL_GetVersion();
    Util.engine_logger.debug("SDL {d}.{d}.{d}", .{
        @divTrunc(version, 1_000_000),
        @rem(@divTrunc(version, 1_000), 1_000),
        @rem(version, 1_000),
    });

    var flags: sdl3.video.Window.Flags = .{
        .fullscreen = fullscreen,
        .resizable = resizable,
        .high_pixel_density = true,
    };

    if (api == .opengl) {
        // macOS is Vulkan-only; this GL path targets Windows/Linux.
        // Match GLFW's default framebuffer config (8/8/8/8, 24-bit depth,
        // 8-bit stencil) rather than SDL's leaner defaults.
        sdl3.video.gl.setAttribute(.red_size, 8) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.green_size, 8) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.blue_size, 8) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.alpha_size, 8) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.depth_size, 24) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.stencil_size, 8) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.double_buffer, 1) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.context_major_version, 4) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.context_minor_version, 5) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.context_profile_mask, @intCast(@intFromEnum(sdl3.video.gl.Profile.core))) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setAttribute(.framebuffer_srgb_capable, 0) catch return error.SurfaceInitFailed;
        flags.open_gl = true;
        Util.engine_logger.debug("Requesting OpenGL Core 4.5!", .{});
    } else if (api == .vulkan) {
        // macOS: MoltenVK is linked into the exe directly (no Vulkan loader).
        // SDL's default bare-name search finds the already-loaded image in
        // dev runs and the bundled libMoltenVK.dylib via the exe rpath in
        // .app bundles; fall back to the explicit leaf name if it misses.
        sdl3.vulkan.loadLibrary(null) catch {
            if (builtin.target.os.tag == .macos) {
                sdl3.vulkan.loadLibrary("libMoltenVK.dylib") catch return error.VulkanNotSupported;
            } else {
                return error.VulkanNotSupported;
            }
        };
        flags.vulkan = true;
        Util.engine_logger.debug("Requesting Vulkan!", .{});
    }

    self.window = sdl3.video.Window.init(title, width, height, flags) catch return error.SurfaceInitFailed;
    errdefer self.window.deinit();

    if (api == .opengl) {
        self.gl_context = sdl3.video.gl.Context.init(self.window) catch return error.SurfaceInitFailed;
        sdl3.video.gl.setSwapInterval(if (sync) .synchronized else .immediate) catch {};
    }

    // Trigger initial size fetch
    self.refresh_size();
}

pub fn deinit(self: *Self) void {
    if (self.gl_context) |ctx| {
        ctx.deinit() catch {};
        self.gl_context = null;
    }
    self.window.deinit();
    if (api == .vulkan) sdl3.vulkan.unloadLibrary();
    sdl3.quit(SDL_VIDEO_FLAGS);
}

pub fn update(self: *Self) bool {
    self.refresh_size();
    return !self.should_quit;
}

pub fn draw(self: *Self) void {
    sdl3.video.gl.swapWindow(self.window) catch {};
}

pub fn get_width(self: *Self) u32 {
    return @intCast(self.width);
}

pub fn get_height(self: *Self) u32 {
    return @intCast(self.height);
}

/// Called by the input backend when SDL reports a quit/close event. Takes
/// effect on the next `update` call, mirroring the old glfwWindowShouldClose
/// polling behavior.
pub fn request_quit(self: *Self) void {
    self.should_quit = true;
}

/// Called by the input backend when the drawable size changes. Fires the
/// resize hook the Vulkan backend uses to flag swapchain recreation.
pub fn notify_resized(self: *Self, width: c_int, height: c_int) void {
    self.width = width;
    self.height = height;
    if (on_resize) |cb| cb();
}

fn refresh_size(self: *Self) void {
    const pixel_width, const pixel_height = self.window.getSizeInPixels() catch return;
    self.width = @intCast(pixel_width);
    self.height = @intCast(pixel_height);
}
