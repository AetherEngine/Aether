const std = @import("std");
const core = @import("../core/input/input.zig");

pub const InitError = error{
    OutOfMemory,
    ContextStackFull,
    InputInitFailed,
    NoCurrentApplication,
};

pub const TextSessionError = core.TextSessionError;

/// Backends deliver raw events to InputSystem and publish each frame.
pub const Interface = struct {
    setup: fn (std.mem.Allocator, std.Io, *core.InputSystem) void,
    init: fn () InitError!void,
    deinit: fn () void,

    /// Drain events, sample peripherals, then call `signal_frame_boundary()`.
    pump: fn (*core.InputSystem) void,

    /// Called before each pump; must be idempotent.
    apply_cursor_mode: fn (core.CursorMode) void,

    /// System keyboards write into the active session; desktop text arrives via `deliver_text`.
    begin_text_input_session: fn (*core.InputSystem, *const core.TextInputTarget, *const core.TextInputOptions) TextSessionError!void,
    end_text_input_session: fn (*core.InputSystem) void,
};

pub fn assert_impl(comptime Backend: type) void {
    @import("contract.zig").assert_impl("input", Backend, Interface);
}
