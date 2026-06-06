//! 3DS input backend. Polls libctru HID once per engine update and
//! translates button, circle-pad, C-stick, trigger, touch, and software
//! keyboard state into Aether's core input events.

const std = @import("std");
const core = @import("../../core/input/input.zig");
const surface = @import("surface.zig");

const Result = c_int;

const TouchPosition = extern struct {
    px: u16,
    py: u16,
};

const CirclePosition = extern struct {
    dx: i16,
    dy: i16,
};

extern fn hidInit() Result;
extern fn hidExit() void;
extern fn hidScanInput() void;
extern fn hidKeysHeld() u32;
extern fn hidTouchRead(pos: *TouchPosition) void;
extern fn hidCircleRead(pos: *CirclePosition) void;

extern fn swkbdInit(swkbd: *anyopaque, typ: c_int, num_buttons: c_int, max_text_length: c_int) void;
extern fn swkbdSetFeatures(swkbd: *anyopaque, features: u32) void;
extern fn swkbdSetHintText(swkbd: *anyopaque, text: [*:0]const u8) void;
extern fn swkbdSetButton(swkbd: *anyopaque, button: c_int, text: [*:0]const u8, submit: bool) void;
extern fn swkbdSetInitialText(swkbd: *anyopaque, text: [*:0]const u8) void;
extern fn swkbdInputText(swkbd: *anyopaque, buf: [*]u8, bufsize: usize) c_int;

const KEY_A: u32 = 1 << 0;
const KEY_B: u32 = 1 << 1;
const KEY_SELECT: u32 = 1 << 2;
const KEY_START: u32 = 1 << 3;
const KEY_DRIGHT: u32 = 1 << 4;
const KEY_DLEFT: u32 = 1 << 5;
const KEY_DUP: u32 = 1 << 6;
const KEY_DDOWN: u32 = 1 << 7;
const KEY_R: u32 = 1 << 8;
const KEY_L: u32 = 1 << 9;
const KEY_X: u32 = 1 << 10;
const KEY_Y: u32 = 1 << 11;
const KEY_ZL: u32 = 1 << 14;
const KEY_ZR: u32 = 1 << 15;
const KEY_TOUCH: u32 = 1 << 20;
const KEY_CSTICK_RIGHT: u32 = 1 << 24;
const KEY_CSTICK_LEFT: u32 = 1 << 25;
const KEY_CSTICK_UP: u32 = 1 << 26;
const KEY_CSTICK_DOWN: u32 = 1 << 27;

const CIRCLE_PAD_MAX: f32 = 156.0;
const MAX_TEXT_BYTES: usize = 1024;
const SWKBD_STATE_BYTES: usize = 0x1000;
const SWKBD_TYPE_NORMAL: c_int = 0;
const SWKBD_BUTTON_LEFT: c_int = 0;
const SWKBD_BUTTON_RIGHT: c_int = 2;
const SWKBD_DARKEN_TOP_SCREEN: u32 = 1 << 1;
const SWKBD_MULTILINE: u32 = 1 << 3;
const SWKBD_DEFAULT_QWERTY: u32 = 1 << 9;

const axis_count = @typeInfo(core.Axis).@"enum".fields.len;

var initialized: bool = false;
var prev_keys: u32 = 0;
var prev_axes: [axis_count]f32 = @splat(0.0);
var prev_touch_down: bool = false;
var prev_touch_pos: core.Vec2 = .{};

pub fn setup(_: std.mem.Allocator, _: std.Io) void {
    initialized = false;
    prev_keys = 0;
    prev_axes = @splat(0.0);
    prev_touch_down = false;
    prev_touch_pos = .{};
}

pub fn init() anyerror!void {
    if (hidInit() != 0) return error.InputInitFailed;
    initialized = true;
}

pub fn deinit() void {
    if (!initialized) return;
    if (surface.is_system_closing()) {
        initialized = false;
        return;
    }
    hidExit();
    initialized = false;
}

pub fn pump() void {
    hidScanInput();
    const keys = hidKeysHeld();

    diff_buttons(keys);
    pump_axes(keys);
    pump_touch(keys);

    prev_keys = keys;
    core.signal_frame_boundary();
}

pub fn apply_cursor_mode(_: core.CursorMode) void {}

pub fn begin_text_input_session(target: core.TextInputTarget, options: core.TextInputOptions) anyerror!void {
    var state_buf: [SWKBD_STATE_BYTES]u8 align(8) = @splat(0);
    const state: *anyopaque = @ptrCast(&state_buf);

    var initial_buf: [MAX_TEXT_BYTES:0]u8 = @splat(0);
    const initial_len = copy_current_text(&initial_buf);
    const initial = initial_buf[0..initial_len :0];

    var hint_buf: [128:0]u8 = @splat(0);
    const hint = copy_z(&hint_buf, target.id);

    const max_text_len = text_limit_c_int(options.max_bytes);
    swkbdInit(state, SWKBD_TYPE_NORMAL, 2, max_text_len);
    swkbdSetInitialText(state, initial.ptr);
    swkbdSetHintText(state, hint.ptr);
    swkbdSetButton(state, SWKBD_BUTTON_LEFT, "Cancel", false);
    swkbdSetButton(state, SWKBD_BUTTON_RIGHT, "OK", true);

    var features = SWKBD_DARKEN_TOP_SCREEN | SWKBD_DEFAULT_QWERTY;
    if (options.multiline) features |= SWKBD_MULTILINE;
    swkbdSetFeatures(state, features);

    var out_buf: [MAX_TEXT_BYTES:0]u8 = @splat(0);
    const out_size = output_buffer_size(options.max_bytes);
    const button = swkbdInputText(state, out_buf[0..].ptr, out_size);
    if (button == SWKBD_BUTTON_RIGHT) {
        const len = bounded_z_len(out_buf[0..out_size]);
        core.write_text_session_buffer(out_buf[0..len], .submitted);
    } else {
        core.write_text_session_buffer(initial_buf[0..initial_len], .cancelled);
    }
}

pub fn end_text_input_session() void {}

fn diff_buttons(keys: u32) void {
    const Pair = struct { mask: u32, button: core.Button };
    const map = [_]Pair{
        .{ .mask = KEY_A, .button = .A },
        .{ .mask = KEY_B, .button = .B },
        .{ .mask = KEY_X, .button = .X },
        .{ .mask = KEY_Y, .button = .Y },
        .{ .mask = KEY_L, .button = .LButton },
        .{ .mask = KEY_R, .button = .RButton },
        .{ .mask = KEY_SELECT, .button = .Back },
        .{ .mask = KEY_START, .button = .Start },
        .{ .mask = KEY_DUP, .button = .DpadUp },
        .{ .mask = KEY_DRIGHT, .button = .DpadRight },
        .{ .mask = KEY_DDOWN, .button = .DpadDown },
        .{ .mask = KEY_DLEFT, .button = .DpadLeft },
    };

    inline for (map) |entry| {
        const now = keys & entry.mask != 0;
        const prev = prev_keys & entry.mask != 0;
        if (now != prev) {
            core.deliver_gamepad_button(entry.button, if (now) .pressed else .released);
        }
    }
}

fn pump_axes(keys: u32) void {
    var circle: CirclePosition = .{ .dx = 0, .dy = 0 };
    hidCircleRead(&circle);

    deliver_axis(.LeftX, normalize_signed(circle.dx, CIRCLE_PAD_MAX));
    deliver_axis(.LeftY, -normalize_signed(circle.dy, CIRCLE_PAD_MAX));
    deliver_axis(.RightX, digital_axis(keys, KEY_CSTICK_RIGHT, KEY_CSTICK_LEFT));
    deliver_axis(.RightY, digital_axis(keys, KEY_CSTICK_DOWN, KEY_CSTICK_UP));
    deliver_axis(.LeftTrigger, if (keys & KEY_ZL != 0) 1.0 else 0.0);
    deliver_axis(.RightTrigger, if (keys & KEY_ZR != 0) 1.0 else 0.0);
}

fn pump_touch(keys: u32) void {
    const touch_down = keys & KEY_TOUCH != 0;
    if (touch_down) {
        var touch: TouchPosition = .{ .px = 0, .py = 0 };
        hidTouchRead(&touch);
        const pos: core.Vec2 = .{
            .x = @floatFromInt(touch.px),
            .y = @floatFromInt(touch.py),
        };
        const delta: core.Vec2 = if (prev_touch_down)
            .{ .x = pos.x - prev_touch_pos.x, .y = pos.y - prev_touch_pos.y }
        else
            .{};

        core.deliver_mouse_move(pos, delta);
        if (!prev_touch_down) core.deliver_mouse_button(.Left, .pressed, pos);
        prev_touch_pos = pos;
    } else if (prev_touch_down) {
        core.deliver_mouse_button(.Left, .released, prev_touch_pos);
    }

    prev_touch_down = touch_down;
}

fn deliver_axis(axis: core.Axis, value: f32) void {
    const idx = @intFromEnum(axis);
    const prev = prev_axes[idx];
    if (value != 0.0 or prev != 0.0) core.deliver_gamepad_axis(axis, value);
    prev_axes[idx] = value;
}

fn normalize_signed(raw: anytype, max_value: f32) f32 {
    const value = @as(f32, @floatFromInt(raw)) / max_value;
    return std.math.clamp(value, -1.0, 1.0);
}

fn digital_axis(keys: u32, positive_mask: u32, negative_mask: u32) f32 {
    var value: f32 = 0.0;
    if (keys & positive_mask != 0) value += 1.0;
    if (keys & negative_mask != 0) value -= 1.0;
    return value;
}

fn output_buffer_size(limit: ?usize) usize {
    const max = @min(limit orelse (MAX_TEXT_BYTES - 1), MAX_TEXT_BYTES - 1);
    return max + 1;
}

fn text_limit_c_int(limit: ?usize) c_int {
    const max = @min(limit orelse (MAX_TEXT_BYTES - 1), MAX_TEXT_BYTES - 1);
    return @intCast(@max(max, 1));
}

fn copy_current_text(dst: []u8) usize {
    const s = core.current_text_session() orelse return 0;
    const n = @min(dst.len - 1, s.buffer.items.len);
    @memcpy(dst[0..n], s.buffer.items[0..n]);
    dst[n] = 0;
    return n;
}

fn copy_z(dst: []u8, text: []const u8) [:0]const u8 {
    const n = @min(dst.len - 1, text.len);
    @memcpy(dst[0..n], text[0..n]);
    dst[n] = 0;
    return dst[0..n :0];
}

fn bounded_z_len(buf: []const u8) usize {
    return std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
}
