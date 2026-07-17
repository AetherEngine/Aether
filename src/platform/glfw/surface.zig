const std = @import("std");
const builtin = @import("builtin");
const surface_api = @import("../surface.zig");
const Util = @import("../../util/util.zig");
const glfw = @import("glfw");

const Self = @This();
const api = @import("options").config.gfx;

// macOS: we link MoltenVK directly as the Vulkan ICD and skip the Vulkan
// loader entirely. Feed MoltenVK's vkGetInstanceProcAddr to GLFW before
// glfwInit so glfwVulkanSupported doesn't dlopen("libvulkan.1.dylib") --
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

pub var on_resize: ?*const fn () void = null;

pub fn init(self: *Self, width: u32, height: u32, title: [:0]const u8, fullscreen: bool, sync: bool, resizable: bool) surface_api.InitError!void {
    // See extern decls above -- bypass GLFW's libvulkan.1.dylib dlopen on macOS.
    // Must run BEFORE glfw.init() per GLFW 3.4 API contract.
    if (builtin.target.os.tag == .macos and api == .vulkan) {
        glfwInitVulkanLoader(&vkGetInstanceProcAddr);
    }

    glfw.initHint(glfw.JoystickHatButtons, 1);

    glfw.init() catch return error.SurfaceInitFailed;

    Util.engine_logger.debug("GLFW {s}", .{glfw.getVersionString()});

    if (api == .opengl) {
        glfw.windowHint(glfw.OpenGLProfile, glfw.OpenGLCoreProfile);
        glfw.windowHint(glfw.ContextVersionMajor, 4);
        glfw.windowHint(glfw.ContextVersionMinor, 5);
        Util.engine_logger.debug("Requesting OpenGL Core 4.5!", .{});
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
        self.window = glfw.createWindow(mode.width, mode.height, title.ptr, monitor, null) catch return error.SurfaceInitFailed;
        self.width = mode.width;
        self.height = mode.height;
    } else {
        self.width = @intCast(width);
        self.height = @intCast(height);

        self.window = glfw.createWindow(@intCast(width), @intCast(height), title.ptr, null, null) catch return error.SurfaceInitFailed;
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
}

export fn framebuffer_size_callback(_: *c_long, width: c_int, height: c_int) void {
    const gfx = @import("../gfx.zig");
    gfx.surface.width = width;
    gfx.surface.height = height;
    if (on_resize) |cb| cb();
}

pub fn deinit(self: *Self) void {
    glfw.destroyWindow(self.window);
}

pub fn update(self: *Self) bool {
    glfw.getFramebufferSize(self.window, &self.width, &self.height);
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
