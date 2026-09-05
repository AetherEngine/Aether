//! Physical input state, independent of action bindings and contexts.

const std = @import("std");
const data = @import("data.zig");

/// Updated by `deliver_*`; evaluated once per engine step.
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
        defer self.* = undefined;

        self.keys.deinit(alloc);
    }

    pub fn axis(self: *const DeviceState, a: data.Axis) f32 {
        return self.gamepad_axes[@intFromEnum(a)];
    }

    pub fn set_axis(self: *DeviceState, a: data.Axis, v: f32) void {
        self.gamepad_axes[@intFromEnum(a)] = v;
    }
};
