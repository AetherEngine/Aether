//! Game actions evaluated from Platform's delivered device state.
//! Handles remain valid when action sets and their maps grow.

const std = @import("std");
const assert = std.debug.assert;
const data = @import("platform").input_api.data;
const binding_mod = @import("binding.zig");

pub const ActionKind = enum(u8) {
    button,
    axis,
    vector2,
};

pub const ActionValue = union(ActionKind) {
    button: data.ButtonState,
    axis: f32,
    vector2: [2]f32,
};

pub const ButtonQuery = struct {
    current: data.ButtonState = .released,
    previous: data.ButtonState = .released,

    pub fn down(self: ButtonQuery) bool {
        return self.current == .pressed;
    }

    pub fn pressed(self: ButtonQuery) bool {
        return self.current == .pressed and self.previous == .released;
    }

    pub fn released(self: ButtonQuery) bool {
        return self.current == .released and self.previous == .pressed;
    }
};

pub const AxisQuery = struct {
    current: f32 = 0.0,
    previous: f32 = 0.0,

    pub fn value(self: AxisQuery) f32 {
        return self.current;
    }

    pub fn delta(self: AxisQuery) f32 {
        return self.current - self.previous;
    }
};

pub const Vector2Query = struct {
    current: [2]f32 = .{ 0.0, 0.0 },
    previous: [2]f32 = .{ 0.0, 0.0 },

    pub fn value(self: Vector2Query) [2]f32 {
        return self.current;
    }

    pub fn delta(self: Vector2Query) [2]f32 {
        return .{
            self.current[0] - self.previous[0],
            self.current[1] - self.previous[1],
        };
    }
};

pub const Action = struct {
    kind: ActionKind,
    bindings: std.ArrayList(binding_mod.Binding) = .empty,
    current_value: ActionValue,
    previous_value: ActionValue,

    pub fn zero(kind: ActionKind) ActionValue {
        return switch (kind) {
            .button => .{ .button = .released },
            .axis => .{ .axis = 0.0 },
            .vector2 => .{ .vector2 = .{ 0.0, 0.0 } },
        };
    }
};

pub const ActionSet = struct {
    name: []const u8,
    actions: std.StringArrayHashMapUnmanaged(Action) = .empty,
    installed: bool = false,
};

pub const ActionSetHandle = enum(u32) { _ };

/// Opaque handle to an action inside an action set. The action index is the
/// insertion-order index in the set's name map. Actions are never removed, so
/// this remains stable across map growth and rehashing.
pub const ActionHandle = packed struct(u64) {
    const null_index = std.math.maxInt(u32);

    set_index: u32 = null_index,
    action_index: u32 = null_index,

    pub const none: ActionHandle = .{};

    pub fn from_parts(action_set: ActionSetHandle, action_index: usize) ActionHandle {
        assert(action_index <= std.math.maxInt(u32));
        return .{
            .set_index = @intFromEnum(action_set),
            .action_index = @intCast(action_index),
        };
    }

    pub fn is_null(self: ActionHandle) bool {
        return self.set_index == null_index or self.action_index == null_index;
    }

    pub fn set(self: ActionHandle) ActionSetHandle {
        return @enumFromInt(self.set_index);
    }
};

pub const DeviceState = @import("platform").input_api.DeviceState;

/// Apply the binding's deadzone and multiplier to its device value.
pub fn binding_contribution(b: binding_mod.Binding, dev: *const DeviceState) f32 {
    var raw: f32 = 0.0;
    switch (b.source) {
        .key => |k| raw = if (dev.keys.contains(k)) 1.0 else 0.0,
        .mouse_button => |mb| raw = if (dev.mouse_buttons.contains(mb)) 1.0 else 0.0,
        .gamepad_button => |gb| raw = if (dev.gamepad_buttons.contains(gb)) 1.0 else 0.0,
        .gamepad_axis => |ga| {
            raw = dev.axis(ga);
            if (raw > b.deadzone) {
                raw = (raw - b.deadzone) / (1.0 - b.deadzone);
            } else if (raw < -b.deadzone) {
                raw = (raw + b.deadzone) / (1.0 - b.deadzone);
            } else {
                raw = 0.0;
            }
        },
        .mouse_delta => |axis_id| raw = switch (axis_id) {
            .x => dev.pointer_delta_accum.x,
            .y => dev.pointer_delta_accum.y,
        },
        .mouse_wheel => |axis_id| raw = switch (axis_id) {
            .x => dev.wheel_accum.x,
            .y => dev.wheel_accum.y,
        },
    }
    return raw * b.multiplier;
}

/// Advance action values, retaining the previous values for edge queries.
pub fn evaluate_set(set: *ActionSet, dev: *const DeviceState) void {
    for (set.actions.values()) |*a| {
        a.previous_value = a.current_value;
        a.current_value = compute(a, dev);
    }
}

/// Recompute a set without creating edges. Used when a context becomes active
/// so already-held inputs do not look like fresh presses.
pub fn sync_set(set: *ActionSet, dev: *const DeviceState) void {
    for (set.actions.values()) |*a| {
        a.current_value = compute(a, dev);
        a.previous_value = a.current_value;
    }
}

pub fn compute(a: *const Action, dev: *const DeviceState) ActionValue {
    return switch (a.kind) {
        .button => blk: {
            for (a.bindings.items) |b| {
                if (binding_contribution(b, dev) > 0.0) break :blk .{ .button = .pressed };
            }
            break :blk .{ .button = .released };
        },
        .axis => blk: {
            var v: f32 = 0.0;
            for (a.bindings.items) |b| v += binding_contribution(b, dev);
            break :blk .{ .axis = v };
        },
        .vector2 => blk: {
            var x: f32 = 0.0;
            var y: f32 = 0.0;
            for (a.bindings.items) |b| {
                if (b.component == .none) continue;
                const c = binding_contribution(b, dev);
                switch (b.component) {
                    .x => x += c,
                    .y => y += c,
                    .none => unreachable,
                }
            }
            break :blk .{ .vector2 = .{ x, y } };
        },
    };
}
