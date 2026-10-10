//! Nintendo 3DS: Zitrus (Horizon) services, Io, and threads; PICA200
//! graphics; DSP audio.
const options = @import("options");

pub const entry = @import("entry.zig");
pub const io = @import("io.zig");
pub const thread = @import("thread.zig");
pub const system = @import("system.zig");
pub const paths = @import("paths.zig");
pub const network = @import("network.zig");
pub const native = @import("native.zig");

pub const gfx = switch (options.config.gfx) {
    .default => @import("gfx.zig"),
    else => @compileError("3DS graphics must be the default PICA200 backend"),
};
pub const surface = @import("surface.zig");
pub const input = @import("input.zig");
pub const audio = @import("audio.zig");
pub const texture_pixels = @import("../graphics/texture_pixels.zig");
