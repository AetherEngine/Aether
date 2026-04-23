const input = @import("../../core/input.zig");

pub fn is_key_down(_: input.Key) bool {
    return false;
}

pub fn is_mouse_button_down(_: input.MouseButton) bool {
    return false;
}

pub fn is_gamepad_button_down(_: input.Button) bool {
    return false;
}

pub fn get_gamepad_axis(_: input.Axis) f32 {
    return 0;
}

pub fn get_mouse_delta(_: f32) [2]f32 {
    return .{ 0, 0 };
}

pub fn get_mouse_motion() [2]f32 {
    return .{ 0, 0 };
}

pub fn get_mouse_scroll() f32 {
    return 0;
}

pub fn set_mouse_relative_mode(_: bool) void {}
