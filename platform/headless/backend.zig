//! Headless device overlay: replaces graphics, surface, input, and (with
//! `-Daudio=none`) audio on any target. Process services, Io, and threads
//! stay the target's own; see `platform/backend.zig`.
pub const gfx = @import("gfx.zig");
pub const surface = @import("surface.zig");
pub const input = @import("input.zig");
pub const audio = @import("audio.zig");
pub const texture_pixels = @import("../graphics/texture_pixels.zig");
