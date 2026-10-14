//! Rebinding waits for a fresh down-edge. Sources held at the start must
//! first be released; key repeats never complete capture.

const std = @import("std");
const data = @import("platform").input.data;
const binding_mod = @import("binding.zig");
const display = @import("display.zig");

pub const CaptureNextInputStatus = enum(u8) {
    waiting,
    captured,
    cancelled,
};

pub const CaptureResult = struct {
    source: binding_mod.BindingSource,
    modifiers: data.ModifierSet,
    display_buf: [64]u8 = @splat(0),
    display_len: u8 = 0,

    pub fn display_label(self: *const CaptureResult) []const u8 {
        return self.display_buf[0..self.display_len];
    }
};

/// Sources held when capture began that have not yet been released.
pub const HeldSources = struct {
    keys: std.EnumSet(data.Key) = .{},
    mouse_buttons: std.EnumSet(data.MouseButton) = .{},
    gamepad_buttons: std.EnumSet(data.Button) = .{},
    gamepad_axes: std.EnumSet(data.Axis) = .{},

    fn contains(self: *const HeldSources, src: binding_mod.BindingSource) bool {
        return switch (src) {
            .key => |k| self.keys.contains(k),
            .mouse_button => |mb| self.mouse_buttons.contains(mb),
            .gamepad_button => |gb| self.gamepad_buttons.contains(gb),
            .gamepad_axis => |a| self.gamepad_axes.contains(a),
            .mouse_wheel, .mouse_delta => false,
        };
    }

    fn remove(self: *HeldSources, src: binding_mod.BindingSource) void {
        switch (src) {
            .key => |k| self.keys.remove(k),
            .mouse_button => |mb| self.mouse_buttons.remove(mb),
            .gamepad_button => |gb| self.gamepad_buttons.remove(gb),
            .gamepad_axis => |a| self.gamepad_axes.remove(a),
            .mouse_wheel, .mouse_delta => {},
        }
    }
};

pub const CaptureNextInputSession = struct {
    eligible_kinds: std.EnumSet(binding_mod.BindingSourceKind),
    held_at_start: HeldSources = .{},
    status: CaptureNextInputStatus = .waiting,
    result: CaptureResult = undefined,

    pub fn is_terminal(self: *const CaptureNextInputSession) bool {
        return self.status == .captured or self.status == .cancelled;
    }
};

pub fn arm_on_release(session: *CaptureNextInputSession, src: binding_mod.BindingSource) void {
    session.held_at_start.remove(src);
}

pub fn eligible_to_complete(session: *const CaptureNextInputSession, src: binding_mod.BindingSource) bool {
    return !session.held_at_start.contains(src);
}

pub fn format_label(buf: *[64]u8, src: binding_mod.BindingSource, mods: data.ModifierSet) u8 {
    const label = display.format_label(buf, src, mods, .readable) catch return 0;
    return @intCast(label.len);
}
