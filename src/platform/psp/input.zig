const input = @import("../../core/input.zig");
const Surface = @import("surface.zig");
const ctrl = @import("pspsdk").ctrl;

pub fn is_key_down(_: input.Key) bool {
    return false;
}

pub fn is_mouse_button_down(_: input.MouseButton) bool {
    return false;
}

pub fn is_gamepad_button_down(button: input.Button) bool {
    const btns = Surface.pad.buttons;
    return switch (button) {
        .A => btns.cross == 1,
        .B => btns.circle == 1,
        .X => btns.square == 1,
        .Y => btns.triangle == 1,
        .LButton => btns.l_trigger == 1,
        .RButton => btns.r_trigger == 1,
        .Back => btns.select == 1,
        .Start => btns.start == 1,
        .Guide => btns.home == 1,
        .LeftThumb => false,
        .RightThumb => false,
        .DpadUp => btns.up == 1,
        .DpadRight => btns.right == 1,
        .DpadDown => btns.down == 1,
        .DpadLeft => btns.left == 1,
    };
}

pub fn get_gamepad_axis(axis: input.Axis) f32 {
    // PSP analog stick: 0-255, center ~128
    // Normalize to -1.0..1.0
    return switch (axis) {
        .LeftX => normalize_axis(Surface.pad.Lx),
        .LeftY => normalize_axis(Surface.pad.Ly),
        .RightX => 0,
        .RightY => 0,
        // PSP has no analog triggers; L/R are digital buttons.
        // Return -1 to mirror GLFW's "fully released" convention.
        .LeftTrigger => -1,
        .RightTrigger => -1,
    };
}

fn normalize_axis(raw: u8) f32 {
    return (@as(f32, @floatFromInt(raw)) - 128.0) / 128.0;
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
