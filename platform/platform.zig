//! Low-level contracts, shared primitives, and the selected target backend.
//!
//! Each subsystem file (`gfx.zig`, `audio.zig`, ...) holds both its backend
//! contract and the dispatch to the backend `backend.zig` selects.
const std = @import("std");
const backend = @import("backend.zig");

pub const entry = @import("entry.zig");
pub const io = @import("io.zig");
pub const thread = @import("thread.zig");
pub const system = @import("system.zig");
pub const paths = @import("paths.zig");
pub const network = @import("network.zig");
pub const gfx = @import("gfx.zig");
pub const surface = @import("surface.zig");
pub const audio = @import("audio.zig");
pub const input = @import("input.zig");
pub const logging = @import("logging.zig");
pub const graphics = @import("graphics/graphics.zig");
pub const math = @import("math/math.zig");
pub const util = @import("util/util.zig");

/// Target-specific services exposed by the public engine facade.
pub const native = backend.target.native;

/// Returns false when the window or application requests shutdown.
pub fn update() bool {
    if (!entry.target.poll()) return false;
    return gfx.surface.update();
}

test {
    std.testing.refAllDecls(@This());
    std.testing.refAllDecls(system);
    std.testing.refAllDecls(network);
    std.testing.refAllDecls(io);
    // Core no longer brings these nested files into Platform's test root.
    std.testing.refAllDecls(input.frame);
    std.testing.refAllDecls(gfx.texture_pixels);
    std.testing.refAllDecls(@import("3ds/fog_state.zig"));
}
