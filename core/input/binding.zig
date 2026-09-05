//! Bindings map device values into action components.

const data = @import("platform").input_api.data;

pub const BindingSourceKind = enum(u8) {
    key,
    mouse_button,
    mouse_wheel,
    mouse_delta,
    gamepad_button,
    gamepad_axis,
};

pub const Vec2Axis = enum(u8) { x, y };

pub const BindingSource = union(BindingSourceKind) {
    key: data.Key,
    mouse_button: data.MouseButton,
    mouse_wheel: Vec2Axis,
    mouse_delta: Vec2Axis,
    gamepad_button: data.Button,
    gamepad_axis: data.Axis,
};

/// Vector2 bindings require x or y; button and scalar bindings use none.
pub const AxisComponent = enum(u8) { x, y, none };

pub const default_axis_deadzone: f32 = 0.4;

pub const Binding = struct {
    source: BindingSource,
    component: AxisComponent = .none,
    multiplier: f32 = 1.0,
    deadzone: f32 = default_axis_deadzone,
};
