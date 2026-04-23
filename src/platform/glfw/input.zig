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
    if (relative_mode) {
        // Delta is computed once per frame in surface.update() —
        // safe to call multiple times per frame (e.g. once per axis).
        return [_]f32{
            @as(f32, @floatCast(Surface.cursor_dx)) * sensitivity,
            @as(f32, @floatCast(Surface.cursor_dy)) * sensitivity,
        };
    } else {
        // Absolute mode: return normalized 0..1 position within the window.
        var win_w: c_int = 0;
        var win_h: c_int = 0;
        glfw.getWindowSize(gfx.surface.window, &win_w, &win_h);
        const w: f64 = @floatFromInt(win_w);
        const h: f64 = @floatFromInt(win_h);
        return [_]f32{ @floatCast(Surface.cursor_x / w), @floatCast((h - Surface.cursor_y) / h) };
    }
}

// Actual per-frame cursor motion (normalized by monitor height, as computed in
// surface.update). Always a delta, regardless of relative/absolute mode — so callers
// judging "did the user move the mouse this frame?" aren't fooled by the cursor-position
// semantics of get_mouse_delta in absolute mode.
pub fn get_mouse_motion() [2]f32 {
    return [_]f32{
        @floatCast(Surface.cursor_dx),
        @floatCast(Surface.cursor_dy),
    };
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
        glfw.setInputMode(gfx.surface.window, glfw.Cursor, glfw.CursorDisabled);
        if (glfw.rawMouseMotionSupported()) {
            glfw.setInputMode(gfx.surface.window, glfw.RawMouseMotion, 1);
        }
        // Seed previous position so the first frame delta is zero.
        glfw.getCursorPos(gfx.surface.window, &Surface.prev_cursor_x, &Surface.prev_cursor_y);
    } else {
        glfw.setInputMode(gfx.surface.window, glfw.RawMouseMotion, 0);
        glfw.setInputMode(gfx.surface.window, glfw.Cursor, glfw.CursorNormal);
        // Seed previous position so the first frame delta is zero.
        glfw.getCursorPos(gfx.surface.window, &Surface.prev_cursor_x, &Surface.prev_cursor_y);
    }
}
