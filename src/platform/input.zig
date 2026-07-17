const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const input_api = @import("input_api.zig");
const core = @import("../core/input/input.zig");

/// Comptime-selected input backend namespace.
pub const api = if (options.config.gfx == .headless)
    @import("headless/input.zig")
else if (builtin.os.tag == .psp)
    @import("psp/input.zig")
else if (options.config.platform == .nintendo_3ds)
    @import("3ds/input.zig")
else if (options.config.platform == .nintendo_switch)
    @import("switch/input.zig")
else if (options.config.platform == .wasm)
    @import("wasm/input.zig")
else
    @import("glfw/input.zig");

comptime {
    input_api.assert_impl(api);
}

pub fn init(input: *core.InputSystem, alloc: std.mem.Allocator, io: std.Io) input_api.InitError!void {
    api.setup(alloc, io, input);
    try api.init();
    input.set_text_session_hooks(api.begin_text_input_session, api.end_text_input_session);
}

pub fn deinit(input: *core.InputSystem) void {
    input.set_text_session_hooks(null, null);
    api.deinit();
}

/// Apply current cursor mode and pump events for the current frame.
/// Pump ends with `input.signal_frame_boundary()` so the published
/// InputFrame is fresh by the time this returns.
pub fn update(input: *core.InputSystem) void {
    api.apply_cursor_mode(input.effective_cursor_mode());
    api.pump(input);
}

pub fn begin_text_input_session(input: *core.InputSystem, target: *const core.TextInputTarget, opts: *const core.TextInputOptions) input_api.TextSessionError!void {
    try api.begin_text_input_session(input, target, opts);
}

pub fn end_text_input_session(input: *core.InputSystem) void {
    api.end_text_input_session(input);
}
