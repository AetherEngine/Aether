//! Headless input backend. No devices, no events, no callbacks.
//!
//! `pump` still calls `signal_frame_boundary` so the published frame
//! advances each step -- game code reading `Core.input.frame()` sees a
//! fresh empty list every update rather than indefinitely-stale data.

const std = @import("std");
const core = @import("../../core/input/input.zig");

pub fn setup(_: std.mem.Allocator, _: std.Io) void {}

pub fn init() anyerror!void {}

pub fn deinit() void {}

pub fn pump() void {
    core.signal_frame_boundary();
}

pub fn apply_cursor_mode(_: core.CursorMode) void {}

pub fn begin_text_input_session(_: core.TextInputTarget, _: core.TextInputOptions) anyerror!void {}

pub fn end_text_input_session() void {}
