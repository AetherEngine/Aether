//! Selects the build target's backend and applies the headless device overlay.
//!
//! Every target folder exposes the same manifest (`<target>/backend.zig`):
//! process services (`entry`, `io`, `thread`, `system`, `paths`, `network`,
//! `native`) and devices (`gfx`, `surface`, `input`, `audio`,
//! `texture_pixels`). `headless/` replaces only devices, so a headless build
//! still runs on the target's own process, I/O, and thread model.

const options = @import("options");

/// Process services for the build target. Devices may be overlaid; use the
/// device declarations below instead of `target.gfx` and friends.
pub const target = switch (options.config.platform) {
    .linux, .macos, .windows => @import("desktop/backend.zig"),
    .psp => @import("psp/backend.zig"),
    .nintendo_3ds => @import("3ds/backend.zig"),
    .nintendo_switch => @import("switch/backend.zig"),
    .wasm => @import("wasm/backend.zig"),
};

const headless = @import("headless/backend.zig");
const headless_video = options.config.gfx == .headless;
const headless_audio = options.config.audio == .none;

pub const gfx = if (headless_video) headless.gfx else target.gfx;
pub const surface = if (headless_video) headless.surface else target.surface;
pub const input = if (headless_video) headless.input else target.input;
pub const audio = if (headless_audio) headless.audio else target.audio;
pub const texture_pixels = if (headless_video) headless.texture_pixels else target.texture_pixels;

/// True when the selected devices are the target's own, so target code may
/// coordinate them directly (for example 3DS applet suspension).
pub const native_video = !headless_video;
pub const native_audio = !headless_audio;
