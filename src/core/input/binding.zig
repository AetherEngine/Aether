//! Action bindings: how a single device source projects into an Action's
//! current value. Multiple bindings combine inside an Action.

const data = @import("data.zig");

pub const BindingSourceKind = enum(u8) {
    key,
    mouse_button,
    mouse_wheel,
    mouse_delta,
    gamepad_button,
    gamepad_axis,
};

/// Subset of axis components excluding `none`. Required for intrinsically
/// axis-bound sources (mouse wheel, mouse delta).
pub const Vec2Axis = enum(u8) { x, y };

pub const BindingSource = union(BindingSourceKind) {
    key: data.Key,
    mouse_button: data.MouseButton,
    mouse_wheel: Vec2Axis,
    mouse_delta: Vec2Axis,
    gamepad_button: data.Button,
    gamepad_axis: data.Axis,
};

/// Selects which component of a Vector2 action a binding contributes to.
/// `none` is meaningful only for button/axis actions where the binding
/// scalar value goes straight into the action value.
pub const AxisComponent = enum(u8) { x, y, none };

pub const default_axis_deadzone: f32 = 0.4;

pub const Binding = struct {
    source: BindingSource,
    component: AxisComponent = .none,
    multiplier: f32 = 1.0,
    deadzone: f32 = default_axis_deadzone,
};
