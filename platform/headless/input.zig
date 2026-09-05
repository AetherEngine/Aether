//! Headless input backend. No devices, no events, no callbacks.
//!
//! `pump` still calls `signal_frame_boundary` so the published frame
//! advances each step -- game code reading `engine.input.current_frame()` sees a
//! fresh empty list every update rather than indefinitely-stale data.

const std = @import("std");
const input_api = @import("../input_api.zig");

pub fn setup(_: std.mem.Allocator, _: std.Io, _: input_api.EventSink) void {}

pub fn init() input_api.InitError!void {}

pub fn deinit() void {}

pub fn pump(input: input_api.EventSink) void {
    input.signal_frame_boundary();
}

pub fn apply_cursor_mode(_: input_api.CursorMode) void {}

pub fn begin_text_input_session(_: input_api.EventSink, _: *const input_api.TextInputRequest) input_api.TextSessionError!void {}

pub fn end_text_input_session(_: input_api.EventSink) void {}
