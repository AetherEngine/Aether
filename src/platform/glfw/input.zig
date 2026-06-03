//! GLFW-driven input backend. Subscribes to per-event callbacks and
//! translates them into `core.deliver_*` calls; polls gamepad state once
//! per pump for axes (which GLFW does not expose via callback).

const std = @import("std");
const glfw = @import("glfw");
const core = @import("../../core/input/input.zig");
const gfx = @import("../gfx.zig");

// -- backend-local state ------------------------------------------------------

var prev_cursor_x: f64 = 0;
var prev_cursor_y: f64 = 0;
var have_prev_cursor: bool = false;
var current_modifiers: core.ModifierSet = .{};
var active_joystick: c_int = -1;
var prev_pad: glfw.GamepadState = .{ .buttons = @splat(0), .axes = @splat(0) };
var have_prev_pad: bool = false;
var current_cursor_mode: core.CursorMode = .visible;
var have_applied_cursor_mode: bool = false;

// -- Interface ---------------------------------------------------------------

pub fn setup(_: std.mem.Allocator, _: std.Io) void {
    prev_cursor_x = 0;
    prev_cursor_y = 0;
    have_prev_cursor = false;
    current_modifiers = .{};
    active_joystick = -1;
    have_prev_pad = false;
    have_applied_cursor_mode = false;
}

pub fn init() anyerror!void {
    const window = gfx.surface.window;
    _ = glfw.updateGamepadMappings(@embedFile("gamecontrollerdb.txt"));
    _ = glfw.setKeyCallback(window, key_callback);
    _ = glfw.setCharCallback(window, char_callback);
    _ = glfw.setMouseButtonCallback(window, mouse_button_callback);
    _ = glfw.setCursorPosCallback(window, cursor_pos_callback);
    _ = glfw.setScrollCallback(window, scroll_callback);
    _ = glfw.setWindowFocusCallback(window, window_focus_callback);
    _ = glfw.setJoystickCallback(joystick_callback);

    // Seed with whichever joystick is present at startup.
    var i: c_int = 0;
    while (i < 16) : (i += 1) {
        if (glfw.joystickPresent(i)) {
            active_joystick = i;
            break;
        }
    }
}

pub fn deinit() void {}

pub fn pump() void {
    glfw.pollEvents();
    pump_gamepad();
    core.signal_frame_boundary();
}

pub fn apply_cursor_mode(mode: core.CursorMode) void {
    if (have_applied_cursor_mode and current_cursor_mode == mode) return;
    have_applied_cursor_mode = true;
    current_cursor_mode = mode;
    const window = gfx.surface.window;
    switch (mode) {
        .captured => {
            glfw.setInputMode(window, glfw.Cursor, glfw.CursorDisabled);
            if (glfw.rawMouseMotionSupported()) {
                glfw.setInputMode(window, glfw.RawMouseMotion, 1);
            }
            glfw.getCursorPos(window, &prev_cursor_x, &prev_cursor_y);
            have_prev_cursor = true;
        },
        .hidden => {
            glfw.setInputMode(window, glfw.RawMouseMotion, 0);
            glfw.setInputMode(window, glfw.Cursor, glfw.CursorHidden);
        },
        .visible, .free => {
            glfw.setInputMode(window, glfw.RawMouseMotion, 0);
            glfw.setInputMode(window, glfw.Cursor, glfw.CursorNormal);
        },
    }
}

pub fn begin_text_input_session(_: core.TextInputTarget, _: core.TextInputOptions) anyerror!void {
    // GLFW backends rely on `deliver_text` from the char callback to
    // populate the session buffer -- no modal OSK to dispatch here.
}

pub fn end_text_input_session() void {}

// -- callbacks ---------------------------------------------------------------

fn convert_mods(mods: c_int) core.ModifierSet {
    var set: core.ModifierSet = .{};
    if (mods & glfw.ModifierShift != 0) set.insert(.shift);
    if (mods & glfw.ModifierControl != 0) set.insert(.ctrl);
    if (mods & glfw.ModifierAlt != 0) set.insert(.alt);
    if (mods & glfw.ModifierSuper != 0) set.insert(.super);
    return set;
}

export fn key_callback(_: *glfw.Window, key: c_int, _: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (key < 0) return;
    const k: core.Key = std.enums.fromInt(core.Key, key) orelse return;
    const m = convert_mods(mods);
    current_modifiers = m;
    switch (action) {
        glfw.Press => core.deliver_key_down(k, m, false),
        glfw.Repeat => core.deliver_key_down(k, m, true),
        glfw.Release => core.deliver_key_up(k, m),
        else => {},
    }
}

export fn char_callback(_: *glfw.Window, codepoint: c_uint) callconv(.c) void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(@intCast(codepoint), &buf) catch return;
    core.deliver_text(buf[0..len]);
}

export fn mouse_button_callback(window: *glfw.Window, button: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (button < 0 or button > 2) return;
    current_modifiers = convert_mods(mods);
    const mb: core.MouseButton = @enumFromInt(button);
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    glfw.getWindowSize(window, &win_w, &win_h);
    glfw.getFramebufferSize(window, &fb_w, &fb_h);
    const sx = @as(f64, @floatFromInt(fb_w)) / @as(f64, @floatFromInt(win_w));
    const sy = @as(f64, @floatFromInt(fb_h)) / @as(f64, @floatFromInt(win_h));
    const pos = core.Vec2{
        .x = @floatCast(prev_cursor_x * sx),
        .y = @floatCast(prev_cursor_y * sy),
    };
    const edge: core.ButtonState = if (action == glfw.Press) .pressed else .released;
    core.deliver_mouse_button(mb, edge, pos);
}

export fn cursor_pos_callback(window: *glfw.Window, xpos: f64, ypos: f64) callconv(.c) void {
    const dx = if (have_prev_cursor) xpos - prev_cursor_x else 0;
    const dy = if (have_prev_cursor) ypos - prev_cursor_y else 0;
    prev_cursor_x = xpos;
    prev_cursor_y = ypos;
    have_prev_cursor = true;
    // GLFW positions are window coordinates, while rendering/UI picking uses
    // framebuffer pixels. Keep the absolute position scaled, but leave the
    // relative delta in GLFW cursor-motion units so mouse-look is not warped
    // or quantized by DPI/content-scale changes.
    var win_w: c_int = 0;
    var win_h: c_int = 0;
    var fb_w: c_int = 0;
    var fb_h: c_int = 0;
    glfw.getWindowSize(window, &win_w, &win_h);
    glfw.getFramebufferSize(window, &fb_w, &fb_h);
    const sx = @as(f64, @floatFromInt(fb_w)) / @as(f64, @floatFromInt(win_w));
    const sy = @as(f64, @floatFromInt(fb_h)) / @as(f64, @floatFromInt(win_h));
    core.deliver_mouse_move(
        .{ .x = @floatCast(xpos * sx), .y = @floatCast(ypos * sy) },
        .{ .x = @floatCast(dx), .y = @floatCast(dy) },
    );
}

export fn scroll_callback(_: *glfw.Window, xoffset: f64, yoffset: f64) callconv(.c) void {
    core.deliver_mouse_wheel(.{ .x = @floatCast(xoffset), .y = @floatCast(yoffset) });
}

export fn window_focus_callback(_: *glfw.Window, focused: c_int) callconv(.c) void {
    core.deliver_focus_change(focused != 0);
}

export fn joystick_callback(id: c_int, event: c_int) callconv(.c) void {
    if (event == glfw.Connected) {
        if (active_joystick == -1) active_joystick = id;
    } else if (event == glfw.Disconnected) {
        if (active_joystick == id) {
            active_joystick = -1;
            have_prev_pad = false;
        }
    }
}

// -- gamepad polling ---------------------------------------------------------

fn pump_gamepad() void {
    if (active_joystick == -1 or !glfw.joystickPresent(active_joystick)) {
        // Lazily rescan if our cached active joystick disappeared.
        active_joystick = -1;
        var i: c_int = 0;
        while (i < 16) : (i += 1) {
            if (glfw.joystickPresent(i)) {
                active_joystick = i;
                break;
            }
        }
        if (active_joystick == -1) return;
    }

    var state: glfw.GamepadState = undefined;
    if (glfw.getGamepadState(active_joystick, &state) == 0) return;

    inline for (std.meta.fields(core.Button)) |f| {
        const b: core.Button = @enumFromInt(f.value);
        const idx = @intFromEnum(b);
        const now = state.buttons[idx];
        const prev = if (have_prev_pad) prev_pad.buttons[idx] else 0;
        if (now != prev) {
            const edge: core.ButtonState = if (now == glfw.Press) .pressed else .released;
            core.deliver_gamepad_button(b, edge);
        }
    }

    inline for (std.meta.fields(core.Axis)) |f| {
        const a: core.Axis = @enumFromInt(f.value);
        const idx = @intFromEnum(a);
        var raw: f32 = state.axes[idx];
        // GLFW reports triggers as -1 at rest, 1 fully pressed. Remap to
        // 0..1 here so core never sees the at-rest -1 noise.
        if (a == .LeftTrigger or a == .RightTrigger) {
            raw = (raw + 1.0) * 0.5;
        }
        const prev_raw_v: f32 = if (have_prev_pad) prev_pad.axes[idx] else 0;
        const prev_raw: f32 = if (a == .LeftTrigger or a == .RightTrigger)
            (prev_raw_v + 1.0) * 0.5
        else
            prev_raw_v;
        // Emit when active OR when transitioning back to zero, so core's
        // device state lands on zero rather than stranded mid-stick.
        if (raw != 0 or prev_raw != 0) {
            core.deliver_gamepad_axis(a, raw);
        }
    }

    prev_pad = state;
    have_prev_pad = true;
}
