const std = @import("std");
const zitrus = @import("zitrus");
const app_3ds = @import("app.zig");
const input_api = @import("../input_api.zig");
const core = @import("../../core/input/input.zig");
const audio = @import("../audio.zig");
const gfx = @import("../gfx.zig");

const horizon = zitrus.horizon;
const Hid = horizon.services.Hid;
const IrRst = @import("irrst.zig");
const SoftwareKeyboard = horizon.services.Applet.Application.SoftwareKeyboard;

const IR_UPDATE_MS = 10;
const IR_USE_RAW_C_STICK = false;
const STICK_MAX: f32 = 0x9C;
const STICK_DEADZONE: f32 = 0.15;
const MAX_OSK_TEXT_UNITS = 1024;
const MAX_OSK_UTF8_BYTES = MAX_OSK_TEXT_UNITS * 4;
const DEFAULT_OSK_BYTES = 256;
const axis_count = @typeInfo(core.Axis).@"enum".fields.len;

var input_alloc: std.mem.Allocator = undefined;
var ir_service: ?IrRst = null;
var ir_input: ?IrRst.Input = null;
var ir_started: bool = false;
var prev_pad: Hid.Pad.State = std.mem.zeroes(Hid.Pad.State);
var have_prev_pad: bool = false;
var prev_axes: [axis_count]f32 = @splat(0.0);
var prev_touch_down: bool = false;
var prev_touch_pos: core.Vec2 = .{};
var current_cursor_mode: core.CursorMode = .visible;
var active_input: ?*core.InputSystem = null;

pub fn setup(alloc: std.mem.Allocator, _: std.Io, input: *core.InputSystem) void {
    input_alloc = alloc;
    active_input = input;
    reset_state();
}

pub fn init() input_api.InitError!void {
    init_ir();
}

pub fn deinit() void {
    if (active_input) |input| release_touch_if_down(input);

    const must_close = if (app_3ds.currentApplication()) |app| app.app.flags.must_close else true;
    if (ir_service) |service| {
        if (ir_started and !must_close) service.sendShutdown() catch {};
        if (ir_input) |*input| input.deinit();
        service.close();
    }
    ir_service = null;
    ir_input = null;
    ir_started = false;
    active_input = null;
    reset_state();
}

pub fn pump(input: *core.InputSystem) void {
    if (app_3ds.currentApplication()) |app| {
        const pad = app.input.pollPad();
        pump_buttons(input, pad);
        pump_left_stick(input, pad);
        pump_touch(input, app.input.pollTouch());
        pump_ir(input);
    }

    input.signal_frame_boundary();
}

pub fn apply_cursor_mode(mode: core.CursorMode) void {
    current_cursor_mode = mode;
}

pub fn begin_text_input_session(input: *core.InputSystem, target: *const core.TextInputTarget, options: *const core.TextInputOptions) input_api.TextSessionError!void {
    const app = app_3ds.currentApplication() orelse return error.NoCurrentApplication;
    var initial_buf: [MAX_OSK_UTF8_BYTES]u8 = undefined;
    const initial = copy_current_text_for_osk(input, &initial_buf, options.*);

    var buttons = [_]SoftwareKeyboard.Config.Button{
        .button(.utf8("Cancel"), .none),
        .button(.utf8("OK"), .submits),
    };
    const hint = valid_utf8_prefix(target.id, SoftwareKeyboard.State.max_hint_text_len - 1);

    const osk_alloc = app.base.gpa;
    var swkbd = SoftwareKeyboard.normal(.{
        .max_length = osk_max_length(options.max_bytes),
        .buttons = &buttons,
        .initial_text = .utf8(initial),
        .hint = if (hint.len == 0) .default else .utf8(hint),
        .features = .{ .multiline = options.multiline },
        .dictionary = &.{},
    }, osk_alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GraphicsNotInitialized,
    };
    defer swkbd.deinit(osk_alloc);

    var released_surface = false;
    var suspended_audio = false;
    const capture = if (@hasDecl(gfx.Surface, "suspend_for_applet")) blk: {
        const capture = gfx.surface.suspend_for_applet() catch return error.GraphicsNotInitialized;
        released_surface = true;
        break :blk capture;
    } else app.gsp.sendImportDisplayCaptureInfo() catch return error.GraphicsNotInitialized;
    audio.Api.suspend_for_applet();
    suspended_audio = true;
    defer {
        if (released_surface) gfx.surface.resume_from_applet();
        if (suspended_audio) audio.Api.resume_from_applet();
    }

    release_touch_if_down(input);
    const result = swkbd.start(app.app, app.apt, .app, app.srv, capture) catch return error.GraphicsNotInitialized;
    if (released_surface) {
        gfx.surface.resume_from_applet();
        released_surface = false;
    }
    if (suspended_audio) {
        audio.Api.resume_from_applet();
        suspended_audio = false;
    }

    switch (result) {
        .right => {
            var out_buf: [MAX_OSK_UTF8_BYTES]u8 = undefined;
            const len = std.unicode.utf16LeToUtf8(&out_buf, swkbd.writtenText()) catch 0;
            const text = clamp_utf8_to_max_bytes(out_buf[0..len], options.max_bytes);
            input.write_text_session_buffer(text, .submitted);
        },
        else => input.write_text_session_buffer(initial, .cancelled),
    }
}

pub fn end_text_input_session(_: *core.InputSystem) void {}

fn init_ir() void {
    const app = app_3ds.currentApplication() orelse return;

    const service = IrRst.open(app.srv) catch return;

    service.sendInitialize(IR_UPDATE_MS, IR_USE_RAW_C_STICK) catch {
        service.close();
        return;
    };
    ir_started = true;

    const input = IrRst.Input.init(service) catch {
        service.sendShutdown() catch {};
        service.close();
        ir_started = false;
        return;
    };

    ir_service = service;
    ir_input = input;
}

fn pump_buttons(input: *core.InputSystem, entry: Hid.Pad.Entry) void {
    const current = entry.current;
    const previous = if (have_prev_pad) prev_pad else std.mem.zeroes(Hid.Pad.State);

    diff_button(input, current.a, previous.a, .A);
    diff_button(input, current.b, previous.b, .B);
    diff_button(input, current.x, previous.x, .X);
    diff_button(input, current.y, previous.y, .Y);
    diff_button(input, current.l, previous.l, .LButton);
    diff_button(input, current.r, previous.r, .RButton);
    diff_button(input, current.select, previous.select, .Back);
    diff_button(input, current.start, previous.start, .Start);
    diff_button(input, current.up, previous.up, .DpadUp);
    diff_button(input, current.right, previous.right, .DpadRight);
    diff_button(input, current.down, previous.down, .DpadDown);
    diff_button(input, current.left, previous.left, .DpadLeft);

    prev_pad = current;
    have_prev_pad = true;
}

fn pump_left_stick(input: *core.InputSystem, entry: Hid.Pad.Entry) void {
    var x = normalize_stick(entry.circle.x);
    var y = -normalize_stick(entry.circle.y);

    if (x == 0.0) {
        if (entry.current.circle_pad_right) x = 1.0;
        if (entry.current.circle_pad_left) x = -1.0;
    }
    if (y == 0.0) {
        if (entry.current.circle_pad_down) y = 1.0;
        if (entry.current.circle_pad_up) y = -1.0;
    }

    deliver_axis(input, .LeftX, x);
    deliver_axis(input, .LeftY, y);
}

fn pump_ir(input: *core.InputSystem) void {
    const ir = ir_input orelse {
        deliver_axis(input, .RightX, 0.0);
        deliver_axis(input, .RightY, 0.0);
        deliver_axis(input, .LeftTrigger, 0.0);
        deliver_axis(input, .RightTrigger, 0.0);
        return;
    };

    const entry = ir.pollPad();
    var x = normalize_stick(entry.c_stick.x);
    var y = -normalize_stick(entry.c_stick.y);

    if (x == 0.0) {
        if (entry.current.c_stick_right) x = 1.0;
        if (entry.current.c_stick_left) x = -1.0;
    }
    if (y == 0.0) {
        if (entry.current.c_stick_down) y = 1.0;
        if (entry.current.c_stick_up) y = -1.0;
    }

    deliver_axis(input, .RightX, x);
    deliver_axis(input, .RightY, y);
    deliver_axis(input, .LeftTrigger, if (entry.current.zl) 1.0 else 0.0);
    deliver_axis(input, .RightTrigger, if (entry.current.zr) 1.0 else 0.0);
}

fn pump_touch(input: *core.InputSystem, touch: Hid.Touch.State) void {
    if (current_cursor_mode == .captured) {
        release_touch_if_down(input);
        return;
    }

    if (touch.pressed) {
        const pos: core.Vec2 = .{
            .x = @floatFromInt(touch.x),
            .y = @floatFromInt(touch.y),
        };
        const delta: core.Vec2 = if (prev_touch_down)
            .{ .x = pos.x - prev_touch_pos.x, .y = pos.y - prev_touch_pos.y }
        else
            .{};

        input.deliver_mouse_move(pos, delta);
        if (!prev_touch_down) input.deliver_mouse_button(.Left, .pressed, pos);
        prev_touch_pos = pos;
        prev_touch_down = true;
    } else {
        release_touch_if_down(input);
    }
}

fn release_touch_if_down(input: *core.InputSystem) void {
    if (!prev_touch_down) return;
    input.deliver_mouse_button(.Left, .released, prev_touch_pos);
    prev_touch_down = false;
    prev_touch_pos = .{};
}

fn diff_button(input: *core.InputSystem, current: bool, previous: bool, button: core.Button) void {
    if (current == previous) return;
    input.deliver_gamepad_button(button, if (current) .pressed else .released);
}

fn deliver_axis(input: *core.InputSystem, axis: core.Axis, value: f32) void {
    const idx = @intFromEnum(axis);
    const prev = prev_axes[idx];
    if (value != 0.0 or prev != 0.0) input.deliver_gamepad_axis(axis, value);
    prev_axes[idx] = value;
}

fn normalize_stick(raw: i16) f32 {
    const value = @as(f32, @floatFromInt(raw)) / STICK_MAX;
    const clamped = std.math.clamp(value, -1.0, 1.0);
    return if (@abs(clamped) < STICK_DEADZONE) 0.0 else clamped;
}

fn copy_current_text_for_osk(input: *core.InputSystem, dst: []u8, options: core.TextInputOptions) []const u8 {
    const session = input.current_text_session() orelse return "";
    const limit = @min(osk_text_limit(options.max_bytes), dst.len - 1);
    const text = valid_utf8_prefix(session.buffer.items, limit);
    @memcpy(dst[0..text.len], text);
    return dst[0..text.len];
}

fn osk_max_length(limit: ?usize) u16 {
    return @intCast(osk_text_limit(limit) + 1);
}

fn osk_text_limit(limit: ?usize) usize {
    return @min(limit orelse DEFAULT_OSK_BYTES, MAX_OSK_TEXT_UNITS - 1);
}

fn clamp_utf8_to_max_bytes(text: []const u8, limit: ?usize) []const u8 {
    const max = limit orelse return text;
    return valid_utf8_prefix(text, @min(max, text.len));
}

fn valid_utf8_prefix(text: []const u8, limit: usize) []const u8 {
    var n = @min(text.len, limit);
    while (true) {
        const candidate = text[0..n];
        if (std.unicode.utf8ValidateSlice(candidate)) return candidate;
        if (n == 0) return "";
        n -= 1;
        while (n > 0 and is_utf8_continuation(text[n])) : (n -= 1) {}
    }
}

fn is_utf8_continuation(byte: u8) bool {
    return byte & 0xC0 == 0x80;
}

fn reset_state() void {
    ir_service = null;
    ir_input = null;
    ir_started = false;
    prev_pad = std.mem.zeroes(Hid.Pad.State);
    have_prev_pad = false;
    prev_axes = @splat(0.0);
    prev_touch_down = false;
    prev_touch_pos = .{};
    current_cursor_mode = .visible;
}
