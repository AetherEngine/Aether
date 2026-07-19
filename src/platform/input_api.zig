const std = @import("std");
const core = @import("../core/input/input.zig");

pub const InitError = error{
    OutOfMemory,
    ContextStackFull,
    InputInitFailed,
    NoCurrentApplication,
};

pub const TextSessionError = core.TextSessionError;

/// The contract every input backend must satisfy. Each field names a
/// public top-level fn on the backend module and gives its exact type.
/// Mirrors `gfx_api.Interface` so the validation pattern is identical.
///
/// Backends are PRODUCERS that call `input.deliver_*` between
/// `signal_frame_boundary` calls.
pub const Interface = struct {
    setup: fn (std.mem.Allocator, std.Io, *core.InputSystem) void,
    init: fn () InitError!void,
    deinit: fn () void,

    /// One-shot per UPDATE phase. Backends:
    /// - Drain platform event queues (e.g. SDL_PollEvent) so callbacks
    ///   that `deliver_*` have a chance to fire.
    /// - Sample peripherals that aren't callback-driven (gamepad axes,
    ///   PSP pad).
    /// - End by calling `input.signal_frame_boundary()` to publish the
    ///   accumulated frame.
    pump: fn (*core.InputSystem) void,

    /// Apply the cursor_mode read from `stack.top.cursor_mode`. Called
    /// before each pump. Must be idempotent: backends may compare
    /// against a previous mode and no-op when unchanged.
    apply_cursor_mode: fn (core.CursorMode) void,

    /// Optional PSP OSK hook. On platforms with a system OSK (PSP), this
    /// drives the modal keyboard and writes the result into the active
    /// `TextInputSession` via `input.write_text_session_buffer`. On
    /// platforms without one (SDL desktop, headless), it is a no-op so text
    /// flows through `deliver_text` instead.
    begin_text_input_session: fn (*core.InputSystem, *const core.TextInputTarget, *const core.TextInputOptions) TextSessionError!void,
    end_text_input_session: fn (*core.InputSystem) void,
};

pub fn assert_impl(comptime Backend: type) void {
    inline for (std.meta.fields(Interface)) |f| {
        if (!@hasDecl(Backend, f.name)) {
            @compileError("input backend " ++ @typeName(Backend) ++ " is missing decl: " ++ f.name);
        }
        const Actual = @TypeOf(@field(Backend, f.name));
        if (Actual != f.type) {
            @compileError("input backend " ++ @typeName(Backend) ++ "." ++ f.name ++
                " has type " ++ @typeName(Actual) ++ ", expected " ++ @typeName(f.type));
        }
    }
}
