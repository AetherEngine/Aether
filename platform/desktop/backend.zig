//! Desktop (Linux, macOS, Windows): SDL3 windowing, input, and audio; Vulkan
//! or OpenGL graphics; std.Io.Threaded files and sockets; std.Thread tasks.
const options = @import("options");

pub const entry = @import("entry.zig");
pub const io = @import("io.zig");
pub const thread = @import("thread.zig");
pub const system = @import("system.zig");
pub const paths = @import("paths.zig");
pub const network = @import("network.zig");
pub const native = @import("native.zig");

pub const gfx = switch (options.config.gfx) {
    .default, .vulkan => @import("vulkan/gfx.zig"),
    .opengl => @import("opengl/gfx.zig"),
    else => @compileError("desktop graphics must be vulkan or opengl"),
};
pub const surface = @import("surface.zig");
pub const input = @import("input.zig");
pub const audio = @import("audio.zig");
pub const texture_pixels = @import("../graphics/texture_pixels.zig");
