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
/// Backends are PRODUCERS that call `core.deliver_*` between
/// `signal_frame_boundary` calls. They never poll core for state.
pub const Interface = struct {
    setup: fn (std.mem.Allocator, std.Io) void,
    init: fn () InitError!void,
    deinit: fn () void,

    /// One-shot per UPDATE phase. Backends:
    /// - Drain platform event queues (e.g. glfw.pollEvents) so callbacks
    ///   that `deliver_*` have a chance to fire.
    /// - Sample peripherals that aren't callback-driven (gamepad axes,
    ///   PSP pad).
    /// - End by calling `core.signal_frame_boundary()` to publish the
    ///   accumulated frame.
    pump: fn () void,

    /// Apply the cursor_mode read from `stack.top.cursor_mode`. Called
    /// before each pump. Must be idempotent: backends may compare
    /// against a previous mode and no-op when unchanged.
    apply_cursor_mode: fn (core.CursorMode) void,

    /// Optional PSP OSK hook. On platforms with a system OSK (PSP), this
    /// drives the modal keyboard and writes the result into the active
    /// `TextInputSession` via `core.write_text_session_buffer`. On
    /// platforms without one (GLFW, headless), it is a no-op so text
    /// flows through `deliver_text` instead.
    begin_text_input_session: fn (*const core.TextInputTarget, *const core.TextInputOptions) TextSessionError!void,
    end_text_input_session: fn () void,
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
