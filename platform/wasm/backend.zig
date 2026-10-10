//! Browser (WASM): host-imported WebGL, Web Audio, and input; WASI files and
//! clocks; one JS event-loop thread, so the host drives the frame loop.
const options = @import("options");

pub const entry = @import("entry.zig");
pub const io = @import("io.zig");
pub const thread = @import("thread.zig");
pub const system = @import("system.zig");
pub const paths = @import("paths.zig");
pub const network = @import("network.zig");
pub const native = @import("native.zig");

pub const gfx = switch (options.config.gfx) {
    .default, .webgl => @import("gfx.zig"),
    else => @compileError("browser graphics must be webgl"),
};
pub const surface = @import("surface.zig");
pub const input = @import("input.zig");
pub const audio = @import("audio.zig");
pub const texture_pixels = @import("../graphics/texture_pixels.zig");
