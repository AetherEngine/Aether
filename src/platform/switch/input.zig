//! Switch input backend. Polls libnx's pad and touchscreen helpers once per
//! engine update and translates them into Aether core input events.

const std = @import("std");
const input_api = @import("../input_api.zig");
const core = @import("../../core/input/input.zig");
const Util = @import("../../util/util.zig");
const c = @import("../nintendo_c.zig").switch_c;

const HID_NPAD_STYLE_STANDARD: u32 = c.HidNpadStyleTag_NpadFullKey |
    c.HidNpadStyleTag_NpadHandheld |
    c.HidNpadStyleTag_NpadJoyDual |
    c.HidNpadStyleTag_NpadJoyLeft |
    c.HidNpadStyleTag_NpadJoyRight;

const DEFAULT_PAD_MASK: u64 = (@as(u64, 1) << c.HidNpadIdType_No1) |
    (@as(u64, 1) << c.HidNpadIdType_Handheld);

const BUTTON_A: u64 = c.HidNpadButton_A;
const BUTTON_B: u64 = c.HidNpadButton_B;
const BUTTON_X: u64 = c.HidNpadButton_X;
const BUTTON_Y: u64 = c.HidNpadButton_Y;
const BUTTON_STICK_L: u64 = c.HidNpadButton_StickL;
const BUTTON_STICK_R: u64 = c.HidNpadButton_StickR;
const BUTTON_L: u64 = c.HidNpadButton_L;
const BUTTON_R: u64 = c.HidNpadButton_R;
const BUTTON_ZL: u64 = c.HidNpadButton_ZL;
const BUTTON_ZR: u64 = c.HidNpadButton_ZR;
const BUTTON_PLUS: u64 = c.HidNpadButton_Plus;
const BUTTON_MINUS: u64 = c.HidNpadButton_Minus;
const BUTTON_LEFT: u64 = c.HidNpadButton_Left;
const BUTTON_UP: u64 = c.HidNpadButton_Up;
const BUTTON_RIGHT: u64 = c.HidNpadButton_Right;
const BUTTON_DOWN: u64 = c.HidNpadButton_Down;
const BUTTON_LEFT_SL: u64 = c.HidNpadButton_LeftSL;
const BUTTON_LEFT_SR: u64 = c.HidNpadButton_LeftSR;
const BUTTON_RIGHT_SL: u64 = c.HidNpadButton_RightSL;
const BUTTON_RIGHT_SR: u64 = c.HidNpadButton_RightSR;

const JOYSTICK_MAX: f32 = @floatFromInt(c.JOYSTICK_MAX);
const MAX_TEXT_BYTES: usize = 1024;
const SWKBD_CONFIG_BYTES: usize = 0x600;

const axis_count = @typeInfo(core.Axis).@"enum".fields.len;

var initialized: bool = false;
var pad: c.PadState = undefined;
var prev_buttons: u64 = 0;
var prev_axes: [axis_count]f32 = @splat(0.0);
var prev_touch_down: bool = false;
var prev_touch_pos: core.Vec2 = .{};
var current_cursor_mode: core.CursorMode = .visible;

pub fn setup(_: std.mem.Allocator, _: std.Io) void {
    initialized = false;
    pad = std.mem.zeroes(c.PadState);
    prev_buttons = 0;
    prev_axes = @splat(0.0);
    prev_touch_down = false;
    prev_touch_pos = .{};
    current_cursor_mode = .visible;
}

pub fn init() input_api.InitError!void {
    if (c.hidInitialize() != 0) return error.InputInitFailed;
    c.hidInitializeTouchScreen();
    c.padConfigureInput(1, HID_NPAD_STYLE_STANDARD);
    c.padInitializeWithMask(&pad, DEFAULT_PAD_MASK);
    initialized = true;
}

pub fn deinit() void {
    if (!initialized) return;
    c.hidExit();
    initialized = false;
}

pub fn pump() void {
    c.padUpdate(&pad);

    diff_buttons(pad.buttons_cur);
    pump_axes(pad.buttons_cur);
    pump_touch();

    prev_buttons = pad.buttons_cur;
    core.signal_frame_boundary();
}

pub fn apply_cursor_mode(mode: core.CursorMode) void {
    current_cursor_mode = mode;
}

pub fn handle_operation_mode_changed() void {
    if (!initialized) return;

    release_all_input_state();

    var arg: c.HidLaControllerSupportArg = undefined;
    c.hidLaCreateControllerSupportArg(&arg);
    arg.hdr.player_count_min = 1;
    arg.hdr.player_count_max = 1;
    arg.hdr.enable_take_over_connection = 1;
    arg.hdr.enable_left_justify = 1;
    arg.hdr.enable_permit_joy_dual = 1;
    arg.hdr.enable_single_mode = 1;

    var result: c.HidLaControllerSupportResultInfo = std.mem.zeroes(c.HidLaControllerSupportResultInfo);
    const rc = c.hidLaShowControllerSupport(&result, &arg);
    if (rc != 0) {
        Util.engine_logger.warn("Switch controller support applet failed: {d}", .{rc});
    }

    c.padConfigureInput(1, HID_NPAD_STYLE_STANDARD);
    c.padInitializeWithMask(&pad, DEFAULT_PAD_MASK);
    reset_previous_input_state();
}

pub fn begin_text_input_session(target: *const core.TextInputTarget, options: *const core.TextInputOptions) input_api.TextSessionError!void {
    var config_buf: [SWKBD_CONFIG_BYTES]u8 align(8) = @splat(0);
    const config: *anyopaque = @ptrCast(&config_buf);

    var initial_buf: [MAX_TEXT_BYTES:0]u8 = @splat(0);
    const initial_len = copy_current_text(&initial_buf);
    const initial = initial_buf[0..initial_len :0];

    var target_buf: [128:0]u8 = @splat(0);
    const target_text = copy_z(&target_buf, target.id);

    if (c.swkbdCreate(config, 0) != 0) {
        core.write_text_session_buffer(initial_buf[0..initial_len], .cancelled);
        return;
    }
    defer c.swkbdClose(config);

    c.swkbdConfigMakePresetDefault(config);
    c.swkbdConfigSetOkButtonText(config, "OK");
    c.swkbdConfigSetHeaderText(config, target_text.ptr);
    c.swkbdConfigSetGuideText(config, target_text.ptr);
    c.swkbdConfigSetInitialText(config, initial.ptr);

    var out_buf: [MAX_TEXT_BYTES:0]u8 = @splat(0);
    const out_size = output_buffer_size(options.max_bytes);
    if (c.swkbdShow(config, out_buf[0..].ptr, out_size) == 0) {
        const len = bounded_z_len(out_buf[0..out_size]);
        core.write_text_session_buffer(out_buf[0..len], .submitted);
    } else {
        core.write_text_session_buffer(initial_buf[0..initial_len], .cancelled);
    }
}

pub fn end_text_input_session() void {}

fn diff_buttons(buttons: u64) void {
    const Pair = struct { mask: u64, button: core.Button };
    const map = [_]Pair{
        // A/B actions follow Nintendo labels. X/Y are swapped so Aether's
        // semantic X=left, Y=top layout matches Nintendo face positions.
        .{ .mask = BUTTON_A, .button = .A },
        .{ .mask = BUTTON_B, .button = .B },
        .{ .mask = BUTTON_X, .button = .Y },
        .{ .mask = BUTTON_Y, .button = .X },
        .{ .mask = BUTTON_L | BUTTON_LEFT_SL | BUTTON_RIGHT_SL, .button = .LButton },
        .{ .mask = BUTTON_R | BUTTON_LEFT_SR | BUTTON_RIGHT_SR, .button = .RButton },
        .{ .mask = BUTTON_MINUS, .button = .Back },
        .{ .mask = BUTTON_PLUS, .button = .Start },
        .{ .mask = BUTTON_STICK_L, .button = .LeftThumb },
        .{ .mask = BUTTON_STICK_R, .button = .RightThumb },
        .{ .mask = BUTTON_UP, .button = .DpadUp },
        .{ .mask = BUTTON_RIGHT, .button = .DpadRight },
        .{ .mask = BUTTON_DOWN, .button = .DpadDown },
        .{ .mask = BUTTON_LEFT, .button = .DpadLeft },
    };

    inline for (map) |entry| {
        const now = buttons & entry.mask != 0;
        const prev = prev_buttons & entry.mask != 0;
        if (now != prev) {
            core.deliver_gamepad_button(entry.button, if (now) .pressed else .released);
        }
    }
}

fn pump_axes(buttons: u64) void {
    const left = pad.sticks[0];
    const right = pad.sticks[1];

    deliver_axis(.LeftX, normalize_stick(left.x));
    deliver_axis(.LeftY, -normalize_stick(left.y));
    deliver_axis(.RightX, normalize_stick(right.x));
    deliver_axis(.RightY, -normalize_stick(right.y));
    deliver_axis(.LeftTrigger, if (buttons & BUTTON_ZL != 0) 1.0 else 0.0);
    deliver_axis(.RightTrigger, if (buttons & BUTTON_ZR != 0) 1.0 else 0.0);
}

fn pump_touch() void {
    if (current_cursor_mode == .captured) {
        if (prev_touch_down) core.deliver_mouse_button(.Left, .released, prev_touch_pos);
        prev_touch_down = false;
        prev_touch_pos = .{};
        return;
    }

    var states: [1]c.HidTouchScreenState = undefined;
    const state_count = c.hidGetTouchScreenStates(&states, states.len);
    const touch_down = state_count > 0 and states[0].count > 0;

    if (touch_down) {
        const touch = states[0].touches[0];
        const pos: core.Vec2 = .{
            .x = @floatFromInt(touch.x),
            .y = @floatFromInt(touch.y),
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

fn release_all_input_state() void {
    if (prev_buttons != 0) diff_buttons(0);
    inline for (std.meta.fields(core.Axis)) |f| {
        const axis: core.Axis = @enumFromInt(f.value);
        const index = @intFromEnum(axis);
        if (prev_axes[index] != 0.0) deliver_axis(axis, 0.0);
    }
    if (prev_touch_down) core.deliver_mouse_button(.Left, .released, prev_touch_pos);
    core.signal_frame_boundary();
    reset_previous_input_state();
}

fn reset_previous_input_state() void {
    prev_buttons = 0;
    prev_axes = @splat(0.0);
    prev_touch_down = false;
    prev_touch_pos = .{};
}

fn normalize_stick(raw: i32) f32 {
    const value = @as(f32, @floatFromInt(raw)) / JOYSTICK_MAX;
    return std.math.clamp(value, -1.0, 1.0);
}

fn output_buffer_size(limit: ?usize) usize {
    const max = @min(limit orelse (MAX_TEXT_BYTES - 1), MAX_TEXT_BYTES - 1);
    return max + 1;
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
