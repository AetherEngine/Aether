//! Hardware facts and implemented services, independent of game budgets/policy.
const std = @import("std");
const options = @import("options");
const contract = @import("contract.zig");
const backend = @import("backend.zig");
const io = @import("io.zig");
pub const Hardware = enum { desktop, browser, psp_phat, psp_slim, old_3ds, new_3ds, nintendo_switch };

pub const Input = struct {
    pointer: bool = false,
    keyboard: bool = false,
    native_text_entry: bool = false,
    /// Built-in controls only; does not describe hot-plugged controllers.
    built_in_sticks: u2 = 0,
};

pub const Info = struct {
    hardware: Hardware,
    input: Input = .{},
    /// `Util.Thread` can spawn native threads.
    background_workers: bool = true,
    native_thread_priority: bool = false,
    /// ThreadConfig.io enables explicit inheritance when this is false.
    worker_inherits_cwd: bool = true,
    /// Set from `io.zig`.
    rename_replaces_destination: bool = true,
    stream_networking: bool = true,
};

pub const Interface = struct {
    info: fn () Info,
};

comptime {
    contract.assert_impl("system", backend.target.system, Interface);
}

/// Available services and built-in hardware, not application quality settings.
pub fn info() Info {
    var result = backend.target.system.info();
    result.rename_replaces_destination = io.rename_replaces_destination;
    if (options.config.gfx == .headless) result.input = .{};
    return result;
}

test "headless capability queries describe implemented input" {
    if (options.config.gfx == .headless) {
        try std.testing.expect(!info().input.pointer);
        try std.testing.expect(!info().input.native_text_entry);
    }
}
