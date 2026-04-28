//! 3DS input backend stub.
//!
//! Wires up to libctru's `hid` (button state, circle pad, touch) once an
//! SDK is available. For now every reading reads as neutral so the action
//! system is silent on 3DS.

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
