//! SDL3-driven input backend. Pumps the SDL event queue once per update and
//! translates events into `InputSystem.deliver_*` calls; polls gamepad state
//! once per pump (mirrors the old GLFW polling model).

const std = @import("std");
const sdl3 = @import("sdl3");
const input_api = @import("../input_api.zig");
const core = @import("../../core/input/input.zig");
const gfx = @import("../gfx.zig");

// The binding does not re-export the scancode module, so recover the payload
// field's type from the event struct.
const SdlScancode = @typeInfo(@TypeOf(@as(sdl3.events.Keyboard, undefined).scancode)).optional.child;

// -- backend-local state ------------------------------------------------------

var prev_cursor_x: f32 = 0;
var prev_cursor_y: f32 = 0;
var have_prev_cursor: bool = false;
var active_gamepad: ?sdl3.gamepad.Gamepad = null;
var active_gamepad_id: ?sdl3.joystick.Id = null;
var prev_buttons: [button_map.len]bool = @splat(false);
var prev_axes: [axis_map.len]f32 = @splat(0);
var have_prev_pad: bool = false;
var current_cursor_mode: core.CursorMode = .visible;
var have_applied_cursor_mode: bool = false;
var relative_mode: bool = false;

// -- translation tables -------------------------------------------------------
//
// core.Key/Button/Axis values are historical GLFW codes; they are opaque
// constants, so they stay untouched and SDL enums are translated here.

const ButtonMapping = struct { sdl: sdl3.gamepad.Button, core: core.Button };
const button_map = [_]ButtonMapping{
    .{ .sdl = .south, .core = .A },
    .{ .sdl = .east, .core = .B },
    .{ .sdl = .west, .core = .X },
    .{ .sdl = .north, .core = .Y },
    .{ .sdl = .left_shoulder, .core = .LButton },
    .{ .sdl = .right_shoulder, .core = .RButton },
    .{ .sdl = .back, .core = .Back },
    .{ .sdl = .start, .core = .Start },
    .{ .sdl = .guide, .core = .Guide },
    .{ .sdl = .left_stick, .core = .LeftThumb },
    .{ .sdl = .right_stick, .core = .RightThumb },
    .{ .sdl = .dpad_up, .core = .DpadUp },
    .{ .sdl = .dpad_right, .core = .DpadRight },
    .{ .sdl = .dpad_down, .core = .DpadDown },
    .{ .sdl = .dpad_left, .core = .DpadLeft },
};

const AxisMapping = struct { sdl: sdl3.gamepad.Axis, core: core.Axis };
const axis_map = [_]AxisMapping{
    .{ .sdl = .left_x, .core = .LeftX },
    .{ .sdl = .left_y, .core = .LeftY },
    .{ .sdl = .right_x, .core = .RightX },
    .{ .sdl = .right_y, .core = .RightY },
    .{ .sdl = .left_trigger, .core = .LeftTrigger },
    .{ .sdl = .right_trigger, .core = .RightTrigger },
};

fn map_scancode(scancode: SdlScancode) ?core.Key {
    return switch (scancode) {
        .space => .Space,
        .apostrophe => .Apostrophe,
        .comma => .Comma,
        .minus => .Minus,
        .period => .Period,
        .slash => .Slash,
        .zero => .Num0,
        .one => .Num1,
        .two => .Num2,
        .three => .Num3,
        .four => .Num4,
        .five => .Num5,
        .six => .Num6,
        .seven => .Num7,
        .eight => .Num8,
        .nine => .Num9,
        .semicolon => .Semicolon,
        .equals => .Equal,
        .a => .A,
        .b => .B,
        .c => .C,
        .d => .D,
        .e => .E,
        .f => .F,
        .g => .G,
        .h => .H,
        .i => .I,
        .j => .J,
        .k => .K,
        .l => .L,
        .m => .M,
        .n => .N,
        .o => .O,
        .p => .P,
        .q => .Q,
        .r => .R,
        .s => .S,
        .t => .T,
        .u => .U,
        .v => .V,
        .w => .W,
        .x => .X,
        .y => .Y,
        .z => .Z,
        .left_bracket => .LeftBracket,
        .backslash => .Backslash,
        .right_bracket => .RightBracket,
        .grave => .GraveAccent,
        .escape => .Escape,
        .return_key => .Enter,
        .tab => .Tab,
        .backspace => .Backspace,
        .insert => .Insert,
        .delete => .Delete,
        .right => .Right,
        .left => .Left,
        .down => .Down,
        .up => .Up,
        .pageup => .PageUp,
        .pagedown => .PageDown,
        .home => .Home,
        .end => .End,
        .caps_lock => .CapsLock,
        .scroll_lock => .ScrollLock,
        .num_lock_clear => .NumLock,
        .print_screen => .PrintScreen,
        .pause => .Pause,
        .func1 => .F1,
        .func2 => .F2,
        .func3 => .F3,
        .func4 => .F4,
        .func5 => .F5,
        .func6 => .F6,
        .func7 => .F7,
        .func8 => .F8,
        .func9 => .F9,
        .func10 => .F10,
        .func11 => .F11,
        .func12 => .F12,
        .kp_0 => .Kp0,
        .kp_1 => .Kp1,
        .kp_2 => .Kp2,
        .kp_3 => .Kp3,
        .kp_4 => .Kp4,
        .kp_5 => .Kp5,
        .kp_6 => .Kp6,
        .kp_7 => .Kp7,
        .kp_8 => .Kp8,
        .kp_9 => .Kp9,
        .kp_decimal => .KpDecimal,
        .kp_divide => .KpDivide,
        .kp_multiply => .KpMultiply,
        .kp_minus => .KpSubtract,
        .kp_plus => .KpAdd,
        .kp_enter => .KpEnter,
        .kp_equals => .KpEqual,
        .left_shift => .LeftShift,
        .left_ctrl => .LeftControl,
        .left_alt => .LeftAlt,
        .left_gui => .LeftSuper,
        .right_shift => .RightShift,
        .right_ctrl => .RightControl,
        .right_alt => .RightAlt,
        .right_gui => .RightSuper,
        .application => .Menu,
        else => null,
    };
}

fn convert_mods(mod: sdl3.keycode.KeyModifier) core.ModifierSet {
    var set: core.ModifierSet = .{};
    if (mod.shiftDown()) set.insert(.shift);
    if (mod.controlDown()) set.insert(.ctrl);
    if (mod.altDown()) set.insert(.alt);
    if (mod.guiDown()) set.insert(.super);
    return set;
}

// -- Interface ---------------------------------------------------------------

pub fn setup(_: std.mem.Allocator, _: std.Io, _: *core.InputSystem) void {
    prev_cursor_x = 0;
    prev_cursor_y = 0;
    have_prev_cursor = false;
    active_gamepad = null;
    active_gamepad_id = null;
    have_prev_pad = false;
    have_applied_cursor_mode = false;
    relative_mode = false;
}

pub fn init() input_api.InitError!void {
    load_gamepad_mappings();

    // Seed with whichever gamepad is present at startup; hot-plug events
    // take over from here.
    if (sdl3.gamepad.getGamepads()) |ids| {
        defer sdl3.free(ids);
        if (ids.len > 0) open_gamepad(ids[0]);
    } else |_| {}

    // Desktop parity with the GLFW char callback: text events always flow,
    // not only during engine text-input sessions.
    sdl3.keyboard.startTextInput(gfx.surface.window) catch {};
}

pub fn deinit() void {
    close_gamepad();
}

pub fn pump(input: *core.InputSystem) void {
    while (sdl3.events.poll()) |event| {
        handle_event(input, event);
    }
    pump_gamepad(input);
    input.signal_frame_boundary();
}

pub fn apply_cursor_mode(mode: core.CursorMode) void {
    if (have_applied_cursor_mode and current_cursor_mode == mode) return;
    have_applied_cursor_mode = true;
    current_cursor_mode = mode;
    const window = gfx.surface.window;
    switch (mode) {
        .captured => {
            // Relative mode also hides the cursor and delivers raw deltas.
            sdl3.mouse.setWindowRelativeMode(window, true) catch {};
            relative_mode = true;
            const buttons, const x, const y = sdl3.mouse.getState();
            _ = buttons;
            prev_cursor_x = x;
            prev_cursor_y = y;
            have_prev_cursor = true;
        },
        .hidden => {
            sdl3.mouse.setWindowRelativeMode(window, false) catch {};
            relative_mode = false;
            sdl3.mouse.hide() catch {};
        },
        .visible, .free => {
            sdl3.mouse.setWindowRelativeMode(window, false) catch {};
            relative_mode = false;
            sdl3.mouse.show() catch {};
        },
    }
}

pub fn begin_text_input_session(_: *core.InputSystem, _: *const core.TextInputTarget, _: *const core.TextInputOptions) input_api.TextSessionError!void {
    // Desktop SDL keeps text input enabled from init (parity with the GLFW
    // char callback), so sessions are populated by `deliver_text` -- no
    // modal OSK to dispatch here.
}

pub fn end_text_input_session(_: *core.InputSystem) void {}

// -- event translation ---------------------------------------------------------

fn handle_event(input: *core.InputSystem, event: sdl3.events.Event) void {
    switch (event) {
        .quit, .window_close_requested => gfx.surface.request_quit(),
        .window_pixel_size_changed => |e| gfx.surface.notify_resized(@intCast(@max(0, e.width)), @intCast(@max(0, e.height))),
        .window_focus_gained => input.deliver_focus_change(true),
        .window_focus_lost => input.deliver_focus_change(false),
        .key_down, .key_up => |e| {
            const scancode = e.scancode orelse return;
            const key = map_scancode(scancode) orelse return;
            const mods = convert_mods(e.mod);
            if (e.down) {
                input.deliver_key_down(key, mods, e.repeat);
            } else {
                input.deliver_key_up(key, mods);
            }
        },
        .text_input => |e| input.deliver_text(e.text),
        .mouse_button_down, .mouse_button_up => |e| {
            const mb: core.MouseButton = switch (e.button) {
                .left => .Left,
                .right => .Right,
                .middle => .Middle,
                // x1/x2 are ignored, matching the old GLFW backend.
                else => return,
            };
            const scale = pixel_scale();
            prev_cursor_x = e.x;
            prev_cursor_y = e.y;
            have_prev_cursor = true;
            input.deliver_mouse_button(
                mb,
                if (e.down) .pressed else .released,
                .{ .x = e.x * scale.x, .y = e.y * scale.y },
            );
        },
        .mouse_motion => |e| {
            const scale = pixel_scale();
            // Absolute position is scaled to framebuffer pixels, but the
            // delta stays in raw cursor-motion units so mouse-look is not
            // warped or quantized by DPI/content-scale changes. In relative
            // mode SDL supplies the raw deltas directly.
            const dx: f32 = if (relative_mode) e.x_rel else if (have_prev_cursor) e.x - prev_cursor_x else 0;
            const dy: f32 = if (relative_mode) e.y_rel else if (have_prev_cursor) e.y - prev_cursor_y else 0;
            prev_cursor_x = e.x;
            prev_cursor_y = e.y;
            have_prev_cursor = true;
            input.deliver_mouse_move(
                .{ .x = e.x * scale.x, .y = e.y * scale.y },
                .{ .x = dx, .y = dy },
            );
        },
        .mouse_wheel => |e| {
            var scroll_x = e.scroll_x;
            var scroll_y = e.scroll_y;
            if (e.direction == .flipped) {
                scroll_x = -scroll_x;
                scroll_y = -scroll_y;
            }
            input.deliver_mouse_wheel(.{ .x = scroll_x, .y = scroll_y });
        },
        .gamepad_added => |e| {
            if (active_gamepad == null) open_gamepad(e.id);
        },
        .gamepad_removed => |e| {
            if (active_gamepad_id) |id| {
                if (id.value == e.id.value) close_gamepad();
            }
        },
        else => {},
    }
}

/// Ratio of drawable pixels to logical window coordinates, used to keep
/// mouse positions in the same framebuffer-pixel space as rendering.
fn pixel_scale() struct { x: f32, y: f32 } {
    const window = gfx.surface.window;
    const window_w, const window_h = window.getSize() catch return .{ .x = 1, .y = 1 };
    const pixel_w, const pixel_h = window.getSizeInPixels() catch return .{ .x = 1, .y = 1 };
    if (window_w == 0 or window_h == 0) return .{ .x = 1, .y = 1 };
    return .{
        .x = @as(f32, @floatFromInt(pixel_w)) / @as(f32, @floatFromInt(window_w)),
        .y = @as(f32, @floatFromInt(pixel_h)) / @as(f32, @floatFromInt(window_h)),
    };
}

// -- gamepad -------------------------------------------------------------------

fn open_gamepad(id: sdl3.joystick.Id) void {
    const pad = sdl3.gamepad.Gamepad.init(id) catch return;
    active_gamepad = pad;
    active_gamepad_id = id;
    have_prev_pad = false;
}

fn close_gamepad() void {
    if (active_gamepad) |pad| pad.deinit();
    active_gamepad = null;
    active_gamepad_id = null;
    have_prev_pad = false;
}

fn pump_gamepad(input: *core.InputSystem) void {
    const pad = active_gamepad orelse return;
    if (!pad.connected()) {
        close_gamepad();
        return;
    }

    var buttons: [button_map.len]bool = undefined;
    inline for (button_map, 0..) |mapping, i| {
        buttons[i] = pad.getButton(mapping.sdl);
        const prev = if (have_prev_pad) prev_buttons[i] else false;
        if (buttons[i] != prev) {
            input.deliver_gamepad_button(mapping.core, if (buttons[i]) .pressed else .released);
        }
    }

    var axes: [axis_map.len]f32 = undefined;
    inline for (axis_map, 0..) |mapping, i| {
        const raw = pad.getAxis(mapping.sdl);
        // SDL rests sticks at 0 and reports triggers on 0..32767, so both
        // map linearly. Clamp stick travel past the nominal range.
        const value = if (mapping.sdl == .left_trigger or mapping.sdl == .right_trigger)
            @as(f32, @floatFromInt(raw)) / 32767.0
        else
            std.math.clamp(@as(f32, @floatFromInt(raw)) / 32767.0, -1.0, 1.0);
        axes[i] = value;
        const prev: f32 = if (have_prev_pad) prev_axes[i] else 0;
        // Emit when active OR when transitioning back to zero, so core's
        // device state lands on zero rather than stranded mid-stick.
        if (value != 0 or prev != 0) {
            input.deliver_gamepad_axis(mapping.core, value);
        }
    }

    prev_buttons = buttons;
    prev_axes = axes;
    have_prev_pad = true;
}

fn load_gamepad_mappings() void {
    var buf: [1024]u8 = undefined;
    var it = std.mem.splitScalar(u8, @embedFile("gamecontrollerdb.txt"), '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line.len >= buf.len) continue;
        @memcpy(buf[0..line.len], line);
        buf[line.len] = 0;
        _ = sdl3.gamepad.addMapping(buf[0..line.len :0]) catch {};
    }
}
