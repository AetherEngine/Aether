//! Per-menu action adaptation. Edge queries remain owned by InputSystem.
const std = @import("std");
const input = @import("../input/input.zig");
const layout = @import("layout.zig");
const Adapter = @This();

pub const Direction = enum { up, down, left, right };
pub const Frame = struct {
    direction: ?Direction = null,
    confirm: bool = false,
    cancel: bool = false,
    pointer: ?layout.Point = null,
    pointer_moved: bool = false,
    pointer_down: bool = false,
    pointer_pressed: bool = false,
    pointer_released: bool = false,
    wheel: i16 = 0,
    input_system: ?*input.InputSystem = null,
};
pub const Actions = struct {
    up: input.ActionHandle = .none,
    down: input.ActionHandle = .none,
    left: input.ActionHandle = .none,
    right: input.ActionHandle = .none,
    confirm: input.ActionHandle = .none,
    cancel: input.ActionHandle = .none,
    pointer: input.ActionHandle = .none,
};
pub const Options = struct {
    repeat_delay: f32 = 0.4,
    repeat_interval: f32 = 0.075,
};
pub const Snapshot = struct {
    buttons: [7]input.ButtonQuery = @splat(.{}),
    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    pointer_active: bool = false,
    pointer_moved: bool = false,
    wheel: f32 = 0,
};

options: Options = .{},
blocked: [7]bool = @splat(false),
remaining: [4]f32 = @splat(0),
wheel_remainder: f32 = 0,
opening: bool = true,

/// Suppress every action held on the next poll until its release. Use whenever
/// this surface opens, even if its action context did not change.
pub fn open(self: *Adapter) void {
    self.blocked = @splat(false);
    self.remaining = @splat(0);
    self.wheel_remainder = 0;
    self.opening = true;
}
pub fn poll(self: *Adapter, system: *input.InputSystem, actions: Actions, delta_seconds: f32, logical_scale: f32) Frame {
    const pointer = system.frame_pointer();
    var snapshot: Snapshot = .{ .pointer_x = pointer.position.x, .pointer_y = pointer.position.y, .pointer_moved = pointer.delta.x != 0 or pointer.delta.y != 0, .pointer_active = system.last_input_mode() == .keyboard_mouse };
    inline for (std.meta.fields(Actions), 0..) |field, i| snapshot.buttons[i] = system.button(@field(actions, field.name));
    for (system.frame_events()) |event| switch (event.kind) {
        .mouse_wheel => |wheel| snapshot.wheel += wheel.delta.y,
        .mouse_move_abs, .mouse_move_rel => snapshot.pointer_moved = true,
        else => {},
    };
    var frame = self.update(snapshot, delta_seconds, logical_scale);
    frame.input_system = system;
    return frame;
}
/// Also useful for application-specific pointer sources and deterministic tests.
/// Invalid/nonfinite timing is treated as zero; invalid scale falls back to 1.
pub fn update(self: *Adapter, snapshot: Snapshot, delta_seconds: f32, logical_scale: f32) Frame {
    const dt = if (std.math.isFinite(delta_seconds)) @max(0, delta_seconds) else 0;
    const scale = if (std.math.isFinite(logical_scale) and logical_scale > 0) logical_scale else 1;
    var frame: Frame = .{ .pointer_moved = snapshot.pointer_moved };
    if (snapshot.pointer_active) frame.pointer = .{ .x = coordinate(snapshot.pointer_x / scale), .y = coordinate(snapshot.pointer_y / scale) };
    for (snapshot.buttons, 0..) |query, i| {
        if (self.opening) self.blocked[i] = query.down();
        if (!query.down()) self.blocked[i] = false;
        if (self.blocked[i]) continue;
        if (i < 4) {
            if (!query.down()) {
                self.remaining[i] = 0;
                continue;
            }
            var fired = query.pressed();
            if (fired) self.remaining[i] = @max(0, self.options.repeat_delay) else {
                self.remaining[i] -= dt;
                if (self.remaining[i] <= 0) {
                    fired = true;
                    self.remaining[i] = @max(0.001, self.options.repeat_interval);
                }
            }
            if (fired and frame.direction == null) frame.direction = @enumFromInt(i);
        } else switch (i) {
            4 => frame.confirm = query.pressed(),
            5 => frame.cancel = query.pressed(),
            6 => {
                frame.pointer_down = query.down();
                frame.pointer_pressed = query.pressed();
                frame.pointer_released = query.released();
            },
            else => unreachable,
        }
    }
    if (std.math.isFinite(snapshot.wheel)) self.wheel_remainder = std.math.clamp(self.wheel_remainder + snapshot.wheel, -32767, 32767);
    frame.wheel = @intFromFloat(@trunc(self.wheel_remainder));
    self.wheel_remainder -= @floatFromInt(frame.wheel);
    self.opening = false;
    return frame;
}
fn coordinate(value: f32) i16 {
    if (!std.math.isFinite(value)) return 0;
    return @intFromFloat(std.math.clamp(@floor(value), -32768, 32767));
}
test "adapter suppresses held menu entry actions and repeats only navigation" {
    var adapter: Adapter = .{};
    var snapshot: Snapshot = .{};
    snapshot.buttons[0] = .{ .current = .pressed };
    snapshot.buttons[4] = .{ .current = .pressed };
    try std.testing.expectEqual(null, adapter.update(snapshot, 1, 1).direction);
    try std.testing.expect(!adapter.update(snapshot, 1, 1).confirm);
    snapshot.buttons = @splat(.{});
    _ = adapter.update(snapshot, 0, 1);
    snapshot.buttons[0] = .{ .current = .pressed };
    snapshot.buttons[4] = .{ .current = .pressed };
    const pressed = adapter.update(snapshot, 0, 1);
    try std.testing.expectEqual(Direction.up, pressed.direction.?);
    try std.testing.expect(pressed.confirm);
    snapshot.buttons[0].previous = .pressed;
    snapshot.buttons[4].previous = .pressed;
    const repeat = adapter.update(snapshot, 0.5, 1);
    try std.testing.expectEqual(Direction.up, repeat.direction.?);
    try std.testing.expect(!repeat.confirm);
}
test "adapter retains fractional wheel and scales coordinates" {
    var adapter: Adapter = .{};
    const snapshot: Snapshot = .{ .pointer_active = true, .pointer_x = 21, .pointer_y = 11, .wheel = 0.6 };
    const first = adapter.update(snapshot, 0, 2);
    try std.testing.expectEqual(layout.Point{ .x = 10, .y = 5 }, first.pointer.?);
    try std.testing.expectEqual(0, first.wheel);
    try std.testing.expectEqual(1, adapter.update(snapshot, 0, 2).wheel);
}
