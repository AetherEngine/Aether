//! Actions, action sets, the action-set registry, and the per-frame
//! evaluator. Game code interacts via handles so the registry is free to
//! relocate ActionSet structs and action maps on grow without dangling
//! references.

const std = @import("std");
const data = @import("data.zig");
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

/// Opaque handle into the registry. Stable across rehashes; passed back
/// to every API call that operates on a set.
pub const ActionSetHandle = enum(u32) { _ };

/// Opaque handle to an action inside an action set. The action index is the
/// insertion-order index in the set's name map. Actions are never removed, so
/// this remains stable across map growth and rehashing.
pub const ActionHandle = packed struct(u64) {
    const Self = @This();
    const null_index = std.math.maxInt(u32);

    set_index: u32 = null_index,
    action_index: u32 = null_index,

    pub const none: Self = .{};

    pub fn from_parts(action_set: ActionSetHandle, action_index: usize) Self {
        std.debug.assert(action_index <= std.math.maxInt(u32));
        return .{
            .set_index = @intFromEnum(action_set),
            .action_index = @intCast(action_index),
        };
    }

    pub fn is_null(self: Self) bool {
        return self.set_index == null_index or self.action_index == null_index;
    }

    pub fn set(self: Self) ActionSetHandle {
        return @enumFromInt(self.set_index);
    }
};

/// Snapshot of currently-held device state. Updated in-place inside each
/// `deliver_*` call. The action evaluator reads it once per frame to
/// compute fresh values for the top context's installed action set.
pub const DeviceState = struct {
    keys: std.AutoHashMapUnmanaged(data.Key, void) = .empty,
    mouse_buttons: std.EnumSet(data.MouseButton) = .{},
    pointer_position: @import("frame.zig").Vec2 = .{},
    pointer_delta_accum: @import("frame.zig").Vec2 = .{},
    wheel_accum: @import("frame.zig").Vec2 = .{},
    gamepad_buttons: std.EnumSet(data.Button) = .{},
    gamepad_axes: [@typeInfo(data.Axis).@"enum".fields.len]f32 = @splat(0.0),
    focused: bool = true,

    pub fn deinit(self: *DeviceState, alloc: std.mem.Allocator) void {
        self.keys.deinit(alloc);
    }

    pub fn axis(self: *const DeviceState, a: data.Axis) f32 {
        return self.gamepad_axes[@intFromEnum(a)];
    }

    pub fn set_axis(self: *DeviceState, a: data.Axis, v: f32) void {
        self.gamepad_axes[@intFromEnum(a)] = v;
    }
};

/// Compute one binding's contribution as a scalar in [-1, 1] (for axes) or
/// {0, 1} (for buttons), post-deadzone, post-multiplier.
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

/// Recompute every action in `set` from `dev`. Caller-owned: callers
/// snapshot previous_value before invoking.
pub fn evaluate_set(set: *ActionSet, dev: *const DeviceState) void {
    var it = set.actions.iterator();
    while (it.next()) |entry| {
        const a = entry.value_ptr;
        a.previous_value = a.current_value;
        a.current_value = compute(a, dev);
    }
}

/// Recompute a set without creating edges. Used when a context becomes active
/// so already-held inputs do not look like fresh presses.
pub fn sync_set(set: *ActionSet, dev: *const DeviceState) void {
    var it = set.actions.iterator();
    while (it.next()) |entry| {
        const a = entry.value_ptr;
        const value = compute(a, dev);
        a.previous_value = value;
        a.current_value = value;
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
