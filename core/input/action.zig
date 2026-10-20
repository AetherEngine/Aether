//! Game actions evaluated from Platform's delivered device state.
//! Storage is fixed-capacity and append-only, so handles never dangle.

const std = @import("std");
const assert = std.debug.assert;
const data = @import("platform").input.data;
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

pub const limits = struct {
    /// Includes the input system's base set.
    pub const max_action_sets: usize = 16;
    pub const max_actions: usize = 128;
    pub const max_bindings: usize = 256;
    pub const max_name_bytes: usize = 32;
};

pub const Name = struct {
    bytes: [limits.max_name_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn init(text: []const u8) error{NameTooLong}!Name {
        if (text.len > limits.max_name_bytes) return error.NameTooLong;
        var name: Name = .{ .len = @intCast(text.len) };
        @memcpy(name.bytes[0..text.len], text);
        return name;
    }

    pub fn slice(self: *const Name) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Action = struct {
    set: ActionSetHandle,
    name: Name,
    kind: ActionKind,
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
    name: Name,
    installed: bool = false,
};

pub const ActionBinding = struct {
    action_index: u32,
    binding: binding_mod.Binding,
};

pub const ActionSetHandle = enum(u32) { _ };

/// Opaque handle to an action inside an action set. The action index is the
/// action's slot in `ActionStore.actions`; lookups also check the set index.
pub const ActionHandle = packed struct(u64) {
    const null_index = std.math.maxInt(u32);

    set_index: u32 = null_index,
    action_index: u32 = null_index,

    pub const none: ActionHandle = .{};

    pub fn from_parts(action_set: ActionSetHandle, action_index: usize) ActionHandle {
        assert(action_index <= std.math.maxInt(u32));
        return .{
            .set_index = @backingInt(action_set),
            .action_index = @intCast(action_index),
        };
    }

    pub fn is_null(self: ActionHandle) bool {
        return self.set_index == null_index or self.action_index == null_index;
    }

    pub fn set(self: ActionHandle) ActionSetHandle {
        return @fromBackingInt(@intCast(self.set_index));
    }
};

pub const DeviceState = @import("platform").input.DeviceState;

/// Apply the binding's deadzone and multiplier to its device value.
pub fn binding_contribution(b: binding_mod.Binding, dev: *const DeviceState) f32 {
    var raw: f32 = 0.0;
    switch (b.source) {
        .key => |k| raw = if (dev.keys.contains(k)) 1.0 else 0.0,
        .mouse_button => |mb| raw = if (dev.mouse_buttons.contains(mb)) 1.0 else 0.0,
        .gamepad_button => |gb| raw = if (dev.gamepad_buttons.contains(gb)) 1.0 else 0.0,
        .gamepad_axis => |ga| {
            raw = dev.axis(ga);
            // Per-axis deadzones crush diagonals on circular-gated sticks, so
            // vector bindings on a stick axis use the stick's radial magnitude.
            const paired: ?data.Axis = switch (ga) {
                .LeftX => .LeftY,
                .LeftY => .LeftX,
                .RightX => .RightY,
                .RightY => .RightX,
                .LeftTrigger, .RightTrigger => null,
            };
            if (b.component != .none and paired != null) {
                const other = dev.axis(paired.?);
                const mag = @sqrt(raw * raw + other * other);
                if (mag <= b.deadzone) {
                    raw = 0.0;
                } else {
                    raw *= (@min(mag, 1.0) - b.deadzone) / (1.0 - b.deadzone) / mag;
                }
            } else if (raw > b.deadzone) {
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

pub const ActionStore = struct {
    sets: [limits.max_action_sets]ActionSet = undefined,
    set_count: usize = 0,
    actions: [limits.max_actions]Action = undefined,
    action_count: usize = 0,
    bindings: [limits.max_bindings]ActionBinding = undefined,
    binding_count: usize = 0,

    pub fn set_ptr(self: *ActionStore, handle: ActionSetHandle) ?*ActionSet {
        const i = @backingInt(handle);
        if (i >= self.set_count) return null;
        return &self.sets[i];
    }

    pub fn action_ptr(self: *ActionStore, handle: ActionHandle) ?*Action {
        if (handle.is_null() or handle.action_index >= self.action_count) return null;
        const a = &self.actions[handle.action_index];
        if (a.set != handle.set()) return null;
        return a;
    }

    pub fn find_action(self: *const ActionStore, set: ActionSetHandle, name: []const u8) ?ActionHandle {
        for (self.actions[0..self.action_count], 0..) |*a, i| {
            if (a.set == set and std.mem.eql(u8, a.name.slice(), name)) return .from_parts(set, i);
        }
        return null;
    }

    /// Recompute a set's actions, keeping the prior values for edge queries.
    pub fn evaluate(self: *ActionStore, set: ActionSetHandle, dev: *const DeviceState) void {
        for (self.actions[0..self.action_count]) |*a| {
            if (a.set == set) a.previous_value = a.current_value;
        }
        self.recompute(set, dev);
    }

    /// Recompute a set without creating edges. Used when a context becomes
    /// active so already-held inputs do not look like fresh presses.
    pub fn sync(self: *ActionStore, set: ActionSetHandle, dev: *const DeviceState) void {
        self.recompute(set, dev);
        for (self.actions[0..self.action_count]) |*a| {
            if (a.set == set) a.previous_value = a.current_value;
        }
    }

    fn recompute(self: *ActionStore, set: ActionSetHandle, dev: *const DeviceState) void {
        for (self.actions[0..self.action_count]) |*a| {
            if (a.set == set) a.current_value = Action.zero(a.kind);
        }
        for (self.bindings[0..self.binding_count]) |entry| {
            const a = &self.actions[entry.action_index];
            if (a.set != set) continue;
            accumulate(&a.current_value, entry.binding, dev);
        }
    }
};

fn accumulate(value: *ActionValue, b: binding_mod.Binding, dev: *const DeviceState) void {
    const c = binding_contribution(b, dev);
    switch (value.*) {
        .button => |*state| if (c > 0.0) {
            state.* = .pressed;
        },
        .axis => |*v| v.* += c,
        .vector2 => |*v| switch (b.component) {
            .x => v[0] += c,
            .y => v[1] += c,
            .none => {},
        },
    }
}

test "bugfix: stick vector bindings use a radial deadzone so diagonals reach full magnitude" {
    var dev: DeviceState = .{};
    const bx: binding_mod.Binding = .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x };
    const by: binding_mod.Binding = .{ .source = .{ .gamepad_axis = .LeftY }, .component = .y };

    dev.gamepad_axes[@backingInt(data.Axis.LeftX)] = 0.7071;
    dev.gamepad_axes[@backingInt(data.Axis.LeftY)] = 0.7071;
    const x = binding_contribution(bx, &dev);
    const y = binding_contribution(by, &dev);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), @sqrt(x * x + y * y), 1e-3);

    dev.gamepad_axes[@backingInt(data.Axis.LeftX)] = 0.35;
    dev.gamepad_axes[@backingInt(data.Axis.LeftY)] = 0.35;
    try std.testing.expect(binding_contribution(bx, &dev) > 0.0);
}
