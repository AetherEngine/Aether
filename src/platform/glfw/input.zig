const std = @import("std");
const input = @import("../../core/input.zig");
const glfw = @import("glfw");
const Surface = @import("surface.zig");
const gfx = @import("../gfx.zig");
// TODO: Agnosticize this to support other backends

pub fn is_key_down(key: input.Key) bool {
    const state = glfw.getKey(gfx.surface.window, @intFromEnum(key));
    return state == glfw.Press;
}

pub fn is_mouse_button_down(button: input.MouseButton) bool {
    const state = glfw.getMouseButton(gfx.surface.window, @intFromEnum(button));
    return state == glfw.Press;
}

pub fn is_gamepad_button_down(button: input.Button) bool {
    var gamepad_state: glfw.GamepadState = undefined;
    _ = glfw.getGamepadState(gfx.surface.active_joystick, &gamepad_state);

    return gamepad_state.buttons[@intFromEnum(button)] == glfw.Press;
}

pub fn get_gamepad_axis(axis: input.Axis) f32 {
    var gamepad_state: glfw.GamepadState = undefined;
    _ = glfw.getGamepadState(gfx.surface.active_joystick, &gamepad_state);

    return gamepad_state.axes[@intFromEnum(axis)];
}

var relative_mode: bool = false;
pub fn get_mouse_delta(sensitivity: f32) [2]f32 {
    // Cursor positions are in screen coordinates, not framebuffer pixels.
    // Use window size (screen coords) to match getCursorPos / setCursorPos.
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    glfw.getWindowSize(gfx.surface.window, &win_w, &win_h);
    const w: f64 = @floatFromInt(win_w);
    const h: f64 = @floatFromInt(win_h);

    if (relative_mode) {
        glfw.setCursorPos(gfx.surface.window, w / 2.0, h / 2.0);

        // Raw screen-coordinate delta — same physical mouse movement gives
        // the same value regardless of window size or DPI.
        return [_]f32{
            @as(f32, @floatCast(Surface.cursor_x - w / 2.0)) * sensitivity,
            @as(f32, @floatCast(Surface.cursor_y - h / 2.0)) * sensitivity,
        };
    } else {
        return [_]f32{ @floatCast(Surface.cursor_x / w), @floatCast((h - Surface.cursor_y) / h) };
    }
}

var last_scroll: f32 = 0.0;
pub fn get_mouse_scroll() f32 {
    const delta = Surface.curr_scroll - last_scroll;
    last_scroll = Surface.curr_scroll;
    return delta;
}

pub fn set_mouse_relative_mode(enabled: bool) void {
    relative_mode = enabled;
    if (enabled) {
        glfw.setInputMode(gfx.surface.window, glfw.Cursor, glfw.CursorHidden);
    } else {
        glfw.setInputMode(gfx.surface.window, glfw.Cursor, glfw.CursorNormal);
    }
}
