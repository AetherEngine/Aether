const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const input_api = @import("input_api.zig");
const core = @import("../core/input/input.zig");

/// Comptime-selected input backend. Pure namespace alias -- backends carry
/// no instance state.
pub const Api = if (options.config.gfx == .headless)
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
    input_api.assert_impl(Api);
}

pub fn init(alloc: std.mem.Allocator, io: std.Io) input_api.InitError!void {
    try core.init(alloc);
    Api.setup(alloc, io);
    try Api.init();
    core.set_text_session_hooks(Api.begin_text_input_session, Api.end_text_input_session);
}

pub fn deinit() void {
    core.set_text_session_hooks(null, null);
    Api.deinit();
    core.deinit();
}

/// Apply current cursor mode and pump events for the current frame.
/// Pump ends with `core.signal_frame_boundary()` so the published
/// InputFrame is fresh by the time this returns.
pub fn update() void {
    Api.apply_cursor_mode(core.effective_cursor_mode());
    Api.pump();
}

pub fn begin_text_input_session(target: *const core.TextInputTarget, opts: *const core.TextInputOptions) input_api.TextSessionError!void {
    try Api.begin_text_input_session(target, opts);
}

pub fn end_text_input_session() void {
    Api.end_text_input_session();
}
