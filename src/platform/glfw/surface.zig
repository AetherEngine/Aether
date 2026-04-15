const std = @import("std");
const builtin = @import("builtin");
const Util = @import("../../util/util.zig");
const glfw = @import("glfw");

const Self = @This();
const api = @import("options").config.gfx;

// macOS: we link MoltenVK directly as the Vulkan ICD and skip the Vulkan
// loader entirely. Feed MoltenVK's vkGetInstanceProcAddr to GLFW before
// glfwInit so glfwVulkanSupported doesn't dlopen("libvulkan.1.dylib") —
// that name lookup hits DYLD_FALLBACK_LIBRARY_PATH (which doesn't include
// /opt/homebrew/...) and either fails outright or picks up a stale
// LunarG SDK loader from /usr/local/lib. Both are common and produce a
// misleading `VulkanNotSupported` error.
//
// These externs resolve at link time because MoltenVK and glfw3 are both
// linked into the exe (see Aether/build.zig macOS branch).
const VulkanProc = *const fn () callconv(.c) void;
extern fn vkGetInstanceProcAddr(instance: ?*anyopaque, name: [*:0]const u8) callconv(.c) ?VulkanProc;
extern fn glfwInitVulkanLoader(loader: *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?VulkanProc) void;

alloc: std.mem.Allocator,
window: *glfw.Window = undefined,
width: c_int = 0,
height: c_int = 0,
active_joystick: c_int = 0,

pub var curr_scroll: f32 = 0;
pub var cursor_x: f64 = 0;
pub var cursor_y: f64 = 0;
pub var prev_cursor_x: f64 = 0;
pub var prev_cursor_y: f64 = 0;
pub var cursor_dx: f64 = 0;
pub var cursor_dy: f64 = 0;

pub var on_resize: ?*const fn () void = null;

pub fn init(self: *Self, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, resizable: bool) anyerror!void {
    self.active_joystick = 0;

    // See extern decls above — bypass GLFW's libvulkan.1.dylib dlopen on macOS.
    // Must run BEFORE glfw.init() per GLFW 3.4 API contract.
    if (builtin.target.os.tag == .macos and api == .vulkan) {
        glfwInitVulkanLoader(&vkGetInstanceProcAddr);
    }

    glfw.initHint(glfw.JoystickHatButtons, 1);

    try glfw.init();

    Util.engine_logger.debug("GLFW {s}", .{glfw.getVersionString()});

    if (api == .opengl) {
        glfw.windowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile);
        glfw.windowHint(glfw.ContextVersionMajor, 4);
        glfw.windowHint(glfw.ContextVersionMinor, 6);
        Util.engine_logger.debug("Requesting OpenGL Core 4.6!", .{});
    } else if (api == .vulkan) {
        glfw.windowHint(glfw.ClientAPI, glfw.NoAPI);

        if (!glfw.vulkanSupported()) {
            return error.VulkanNotSupported;
        }

        Util.engine_logger.debug("Requesting Vulkan!", .{});
    }

    glfw.windowHint(glfw.Resizable, @intFromBool(resizable));
    glfw.windowHint(glfw.SRGBCapable, 0);

    if (fullscreen) {
        const monitor = glfw.getPrimaryMonitor();
        const mode = glfw.getVideoMode(monitor).?;
        self.window = try glfw.createWindow(mode.width, mode.height, title.ptr, monitor, null);
        self.width = mode.width;
        self.height = mode.height;
    } else {
        self.width = @intCast(width);
        self.height = @intCast(height);

        self.window = try glfw.createWindow(@intCast(width), @intCast(height), title.ptr, null, null);
    }

    // OpenGL
    if (api == .opengl) {
        glfw.makeContextCurrent(self.window);
        glfw.swapInterval(@intFromBool(sync));
    }

    // Trigger initial size fetch
    glfw.getFramebufferSize(self.window, &self.width, &self.height);

    // Resize callback
    _ = glfw.setFramebufferSizeCallback(self.window, framebuffer_size_callback);

    // Focus callback
    _ = glfw.setWindowFocusCallback(self.window, window_focus_callback);

    // Input
    _ = glfw.updateGamepadMappings(@embedFile("gamecontrollerdb.txt"));
    _ = glfw.setScrollCallback(self.window, scroll_callback);
}

export fn framebuffer_size_callback(_: *c_long, width: c_int, height: c_int) void {
    const gfx = @import("../gfx.zig");
    gfx.surface.width = width;
    gfx.surface.height = height;
    if (on_resize) |cb| cb();
}

export fn scroll_callback(_: *c_long, _: f64, yoffset: f64) void {
    curr_scroll += @floatCast(yoffset);
}

export fn window_focus_callback(_: *c_long, focused: c_int) void {
    if (focused == 0) {
        const input = @import("../../core/input.zig");
        input.fire_lost_focus();
    }
}

pub fn deinit(self: *Self) void {
    glfw.destroyWindow(self.window);
}

pub fn update(self: *Self) bool {
    glfw.pollEvents();
    glfw.getFramebufferSize(self.window, &self.width, &self.height);

    for (0..16) |joystick| {
        if (glfw.joystickPresent(@intCast(joystick))) {
            self.active_joystick = @intCast(joystick);

            break;
        }
    }

    glfw.getCursorPos(self.window, &cursor_x, &cursor_y);
    const raw_dx = cursor_x - prev_cursor_x;
    const raw_dy = cursor_y - prev_cursor_y;
    prev_cursor_x = cursor_x;
    prev_cursor_y = cursor_y;

    // Normalize by monitor height so sensitivity 1.0 means a full
    // monitor-height sweep produces a delta of 1.0.  This keeps
    // "same physical movement = same delta" across window sizes
    // (we don't use window size) and across resolutions (higher-res
    // monitors have more pixels but the same normalized range).
    const monitor_h: f64 = if (glfw.getVideoMode(glfw.getPrimaryMonitor())) |mode|
        @floatFromInt(mode.height)
    else
        1080.0;
    cursor_dx = raw_dx / monitor_h;
    cursor_dy = raw_dy / monitor_h;
    return !glfw.windowShouldClose(self.window);
}

pub fn draw(self: *Self) void {
    glfw.swapBuffers(self.window);
}

pub fn get_width(self: *Self) u32 {
    return @intCast(self.width);
}

pub fn get_height(self: *Self) u32 {
    return @intCast(self.height);
}
