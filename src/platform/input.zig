const std = @import("std");
const options = @import("options");

const input_api = @import("input_api.zig");
const core = @import("../core/input/input.zig");

pub const api = if (options.config.gfx == .headless)
    @import("headless/input.zig")
else switch (options.config.platform) {
    .psp => @import("psp/input.zig"),
    .nintendo_3ds => @import("3ds/input.zig"),
    .nintendo_switch => @import("switch/input.zig"),
    .wasm => @import("wasm/input.zig"),
    else => @import("sdl/input.zig"),
};

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

/// Publishes a fresh InputFrame before Core evaluates actions.
pub fn update(input: *core.InputSystem) void {
    api.apply_cursor_mode(input.effective_cursor_mode());
    api.pump(input);
}

pub const begin_text_input_session = api.begin_text_input_session;
pub const end_text_input_session = api.end_text_input_session;
