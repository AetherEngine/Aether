//! Platform-owned device events and operating-system input services.
//! Consumers supply an opaque sink; backends never depend on engine policy.

const std = @import("std");
const contract = @import("contract.zig");
pub const data = @import("input/data.zig");
pub const frame = @import("input/frame.zig");
pub const DeviceState = @import("input/device.zig").DeviceState;

pub const Key = data.Key;
pub const MouseButton = data.MouseButton;
pub const Button = data.Button;
pub const Axis = data.Axis;
pub const ModifierSet = data.ModifierSet;
pub const ButtonState = data.ButtonState;
pub const Vec2 = frame.Vec2;

pub const InitError = error{
    OutOfMemory,
    InputInitFailed,
    NoCurrentApplication,
};

pub const TextSessionError = error{
    OutOfMemory,
    NoCurrentApplication,
    GraphicsNotInitialized,
};

pub const CursorMode = enum(u8) {
    captured,
    free,
    hidden,
    visible,
};

/// Borrowed text is valid for the duration of the keyboard request. The
/// caller owns session lifetime, initial-text policy, and submitted text.
pub const TextInputRequest = struct {
    prompt: []const u8,
    initial: []const u8 = "",
    multiline: bool = false,
    max_bytes: ?usize = null,
};

pub const TextInputResult = enum {
    submitted,
    cancelled,
};

/// Text slices are borrowed only during delivery; sinks must copy to retain.
pub const Event = union(enum) {
    key_down: struct { key: Key, modifiers: ModifierSet, is_repeat: bool },
    key_up: struct { key: Key, modifiers: ModifierSet },
    text: []const u8,
    mouse_button: struct { button: MouseButton, edge: ButtonState, position: Vec2 },
    mouse_move: struct { position: Vec2, delta: Vec2 },
    mouse_wheel: Vec2,
    gamepad_button: struct { button: Button, edge: ButtonState },
    gamepad_axis: struct { axis: Axis, value: f32 },
    focus_change: bool,
    text_completed: struct { text: []const u8, result: TextInputResult },
    frame_boundary,
};

/// A copyable callback handle. Its context must outlive backend setup through
/// deinit, including browser callbacks and modal keyboard invocations.
pub const EventSink = struct {
    context: *anyopaque,
    on_event: *const fn (*anyopaque, Event) void,

    pub fn deliver_key_down(self: EventSink, key: Key, mods: ModifierSet, is_repeat: bool) void {
        self.on_event(self.context, .{ .key_down = .{ .key = key, .modifiers = mods, .is_repeat = is_repeat } });
    }

    pub fn deliver_key_up(self: EventSink, key: Key, mods: ModifierSet) void {
        self.on_event(self.context, .{ .key_up = .{ .key = key, .modifiers = mods } });
    }

    pub fn deliver_text(self: EventSink, text: []const u8) void {
        self.on_event(self.context, .{ .text = text });
    }

    pub fn deliver_mouse_button(self: EventSink, button: MouseButton, edge: ButtonState, position: Vec2) void {
        self.on_event(self.context, .{ .mouse_button = .{ .button = button, .edge = edge, .position = position } });
    }

    pub fn deliver_mouse_move(self: EventSink, position: Vec2, delta: Vec2) void {
        self.on_event(self.context, .{ .mouse_move = .{ .position = position, .delta = delta } });
    }

    pub fn deliver_mouse_wheel(self: EventSink, delta: Vec2) void {
        self.on_event(self.context, .{ .mouse_wheel = delta });
    }

    pub fn deliver_gamepad_button(self: EventSink, button: Button, edge: ButtonState) void {
        self.on_event(self.context, .{ .gamepad_button = .{ .button = button, .edge = edge } });
    }

    pub fn deliver_gamepad_axis(self: EventSink, axis: Axis, value: f32) void {
        self.on_event(self.context, .{ .gamepad_axis = .{ .axis = axis, .value = value } });
    }

    pub fn deliver_focus_change(self: EventSink, gained: bool) void {
        self.on_event(self.context, .{ .focus_change = gained });
    }

    pub fn complete_text(self: EventSink, text: []const u8, result: TextInputResult) void {
        self.on_event(self.context, .{ .text_completed = .{ .text = text, .result = result } });
    }

    pub fn signal_frame_boundary(self: EventSink) void {
        self.on_event(self.context, .frame_boundary);
    }
};

pub const Interface = struct {
    setup: fn (std.mem.Allocator, std.Io, EventSink) void,
    init: fn () InitError!void,
    deinit: fn () void,

    /// Drain events, sample peripherals, then publish a frame boundary.
    pump: fn (EventSink) void,

    /// Called before each pump; must be idempotent.
    apply_cursor_mode: fn (CursorMode) void,

    /// System keyboards return a result through the sink. Desktop text
    /// continues to arrive through `deliver_text` while a session is active.
    begin_text_input_session: fn (EventSink, *const TextInputRequest) TextSessionError!void,
    end_text_input_session: fn (EventSink) void,
};

pub fn assert_impl(comptime Backend: type) void {
    contract.assert_impl("input", Backend, Interface);
}
