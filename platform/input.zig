//! Selects and drives the platform's physical input backend.

const std = @import("std");
const options = @import("options");

pub const input_api = @import("input_api.zig");
pub const EventSink = input_api.EventSink;
pub const CursorMode = input_api.CursorMode;

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

pub fn init(sink: EventSink, alloc: std.mem.Allocator, io: std.Io) input_api.InitError!void {
    api.setup(alloc, io, sink);
    try api.init();
}

pub fn deinit() void {
    api.deinit();
}

/// Deliver a fresh device frame using the cursor mode chosen by the caller.
pub fn update(sink: EventSink, cursor_mode: CursorMode) void {
    api.apply_cursor_mode(cursor_mode);
    api.pump(sink);
}

pub const begin_text_input_session = api.begin_text_input_session;
pub const end_text_input_session = api.end_text_input_session;
