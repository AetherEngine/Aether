const std = @import("std");
const zitrus = @import("zitrus");
const app_3ds = @import("app.zig");
const core = @import("../../core/input/input.zig");
const gfx = @import("../gfx.zig");

const horizon = zitrus.horizon;
const Hid = horizon.services.Hid;
const IrRst = @import("irrst.zig");
const SoftwareKeyboard = horizon.services.Applet.Application.SoftwareKeyboard;

const IR_UPDATE_MS = 10;
const STICK_MAX: f32 = 0x9C;
const MAX_OSK_BYTES = 1024;
const DEFAULT_OSK_BYTES = 256;
const axis_count = @typeInfo(core.Axis).@"enum".fields.len;

var input_alloc: std.mem.Allocator = undefined;
var ir_service: ?IrRst = null;
var ir_input: ?IrRst.Input = null;
var ir_started: bool = false;
var prev_axes: [axis_count]f32 = @splat(0.0);
var prev_touch_down: bool = false;
var prev_touch_pos: core.Vec2 = .{};
var current_cursor_mode: core.CursorMode = .visible;

pub fn setup(alloc: std.mem.Allocator, _: std.Io) void {
    input_alloc = alloc;
    reset_state();
}

pub fn init() anyerror!void {
    init_ir();
}

pub fn deinit() void {
    release_touch_if_down();

    const must_close = if (app_3ds.currentApplication()) |app| app.app.flags.must_close else true;
    if (ir_service) |service| {
        if (ir_started and !must_close) service.sendShutdown() catch {};
        if (ir_input) |*input| input.deinit();
        service.close();
    }
    ir_service = null;
    ir_input = null;
    ir_started = false;
    reset_state();
}

pub fn pump() void {
    if (app_3ds.currentApplication()) |app| {
        const pad = app.input.pollPad();
        pump_buttons(pad);
        pump_left_stick(pad);
        pump_touch(app.input.pollTouch());
        pump_ir();
    }

    core.signal_frame_boundary();
}

pub fn apply_cursor_mode(mode: core.CursorMode) void {
    current_cursor_mode = mode;
}

pub fn begin_text_input_session(target: core.TextInputTarget, options: core.TextInputOptions) anyerror!void {
    const app = app_3ds.currentApplication() orelse return error.NoCurrentApplication;
    var initial_buf: [MAX_OSK_BYTES]u8 = undefined;
    const initial = copy_current_text_for_osk(&initial_buf, options);

    var buttons = [_]SoftwareKeyboard.Config.Button{
        .{ .label = .default, .submits_text = true },
    };
    const hint = valid_utf8_prefix(target.id, SoftwareKeyboard.State.max_hint_text_len - 1);

    var swkbd = try SoftwareKeyboard.normal(.{
        .max_length = osk_max_length(options.max_bytes),
        .buttons = &buttons,
        .initial_text = .utf8(initial),
        .hint = if (hint.len == 0) .default else .utf8(hint),
        .features = .{ .multiline = options.multiline },
        .dictionary = &.{},
    }, input_alloc);
    defer swkbd.deinit(input_alloc);

    var released_surface = false;
    const capture = if (@hasDecl(gfx.Surface, "suspend_for_applet")) blk: {
        const capture = try gfx.surface.suspend_for_applet();
        released_surface = true;
        break :blk capture;
    } else try app.gsp.sendImportDisplayCaptureInfo();
    defer if (released_surface) gfx.surface.resume_from_applet();

    const result = try swkbd.start(app.app, app.apt, .app, app.srv, capture);

    switch (result) {
        .right => {
            var out_buf: [MAX_OSK_BYTES]u8 = undefined;
            const len = std.unicode.utf16LeToUtf8(&out_buf, swkbd.writtenText()) catch 0;
            core.write_text_session_buffer(out_buf[0..len], .submitted);
        },
        else => core.write_text_session_buffer(initial, .cancelled),
    }
}

pub fn end_text_input_session() void {}

fn init_ir() void {
    const app = app_3ds.currentApplication() orelse return;

    const service = IrRst.open(app.srv) catch return;

    service.sendInitialize(IR_UPDATE_MS, true) catch {
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

fn pump_buttons(entry: Hid.Pad.Entry) void {
    deliver_button(entry.pressed.a, entry.released.a, .A);
    deliver_button(entry.pressed.b, entry.released.b, .B);
    deliver_button(entry.pressed.x, entry.released.x, .X);
    deliver_button(entry.pressed.y, entry.released.y, .Y);
    deliver_button(entry.pressed.l, entry.released.l, .LButton);
    deliver_button(entry.pressed.r, entry.released.r, .RButton);
    deliver_button(entry.pressed.select, entry.released.select, .Back);
    deliver_button(entry.pressed.start, entry.released.start, .Start);
    deliver_button(entry.pressed.up, entry.released.up, .DpadUp);
    deliver_button(entry.pressed.right, entry.released.right, .DpadRight);
    deliver_button(entry.pressed.down, entry.released.down, .DpadDown);
    deliver_button(entry.pressed.left, entry.released.left, .DpadLeft);
}

fn pump_left_stick(entry: Hid.Pad.Entry) void {
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

    deliver_axis(.LeftX, x);
    deliver_axis(.LeftY, y);
}

fn pump_ir() void {
    const input = ir_input orelse {
        deliver_axis(.RightX, 0.0);
        deliver_axis(.RightY, 0.0);
        deliver_axis(.LeftTrigger, 0.0);
        deliver_axis(.RightTrigger, 0.0);
        return;
    };

    const entry = input.pollPad();
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

    deliver_axis(.RightX, x);
    deliver_axis(.RightY, y);
    deliver_axis(.LeftTrigger, if (entry.current.zl) 1.0 else 0.0);
    deliver_axis(.RightTrigger, if (entry.current.zr) 1.0 else 0.0);
}

fn pump_touch(touch: Hid.Touch.State) void {
    if (current_cursor_mode == .captured) {
        release_touch_if_down();
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

        core.deliver_mouse_move(pos, delta);
        if (!prev_touch_down) core.deliver_mouse_button(.Left, .pressed, pos);
        prev_touch_pos = pos;
        prev_touch_down = true;
    } else {
        release_touch_if_down();
    }
}

fn release_touch_if_down() void {
    if (!prev_touch_down) return;
    core.deliver_mouse_button(.Left, .released, prev_touch_pos);
    prev_touch_down = false;
    prev_touch_pos = .{};
}

fn deliver_button(pressed: bool, released: bool, button: core.Button) void {
    if (pressed) core.deliver_gamepad_button(button, .pressed);
    if (released) core.deliver_gamepad_button(button, .released);
}

fn deliver_axis(axis: core.Axis, value: f32) void {
    const idx = @intFromEnum(axis);
    if (prev_axes[idx] == value) return;
    core.deliver_gamepad_axis(axis, value);
    prev_axes[idx] = value;
}

fn normalize_stick(raw: i16) f32 {
    const value = @as(f32, @floatFromInt(raw)) / STICK_MAX;
    return std.math.clamp(value, -1.0, 1.0);
}

fn copy_current_text_for_osk(dst: []u8, options: core.TextInputOptions) []const u8 {
    const session = core.current_text_session() orelse return "";
    const limit = @min(options.max_bytes orelse DEFAULT_OSK_BYTES, MAX_OSK_BYTES - 1);
    const text = valid_utf8_prefix(session.buffer.items, limit);
    @memcpy(dst[0..text.len], text);
    return dst[0..text.len];
}

fn osk_max_length(limit: ?usize) u16 {
    const max = @min(limit orelse DEFAULT_OSK_BYTES, MAX_OSK_BYTES - 1);
    return @intCast(max + 1);
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
    prev_axes = @splat(0.0);
    prev_touch_down = false;
    prev_touch_pos = .{};
    current_cursor_mode = .visible;
}
