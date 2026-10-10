//! Entry contract shared by every target.
//!
//! The executable root (`platform/root/<target>.zig`) declares what std and
//! the target SDK read from `@import("root")`, then calls into its target's
//! `entry.zig`. That file brings up process services and runs the
//! application's `main` with an `AetherIo` in `std.process.Init.io`.

const std = @import("std");
const contract = @import("contract.zig");
const io = @import("io.zig");

/// The application's `main`, adapted by the root to a uniform signature.
pub const AppMain = *const fn (std.process.Init) anyerror!void;

/// A frame loop the host drives instead of a blocking `while` (WASM).
pub const FrameLoop = struct {
    context: *anyopaque,
    /// Runs one frame; false once the loop has stopped.
    step: *const fn (*anyopaque) bool,
    /// Tears the loop's owner down after the host stops calling `step`.
    finish: *const fn (*anyopaque) void,
};

pub const Interface = struct {
    /// True when the host calls into the app once per frame, so a blocking
    /// run loop must be handed to `host_frame_loop` instead.
    hosts_frame_loop: bool,
    /// Handles process events (applets, sleep, quit) once per frame before
    /// the surface updates. False when the OS asks the app to exit.
    poll: fn () bool,
};

/// The selected target's entry: start functions the root calls.
pub const target = @import("backend.zig").target.entry;

comptime {
    contract.assert_impl("entry", target, Interface);
}

pub const hosts_frame_loop = target.hosts_frame_loop;

/// Hands the run loop to the host. Only valid when `hosts_frame_loop`.
pub fn host_frame_loop(loop: FrameLoop) void {
    if (comptime !hosts_frame_loop) unreachable;
    target.host_frame_loop(loop);
}

/// Runs `app_main` with `init.io` replaced by an AetherIo over it.
pub fn run_app(init: std.process.Init, app_main: AppMain) anyerror!void {
    var aether_io: io.AetherIo = .init(init.io, init.gpa);
    var app_init = init;
    app_init.io = aether_io.io();
    return app_main(app_init);
}
