//! Browser input backend. JavaScript event listeners translate DOM input into
//! Aether enum integer values and call the exported delivery functions below.

const std = @import("std");
const input_api = @import("../input_api.zig");
const core = @import("../../core/input/input.zig");

extern "aether_host" fn aether_input_apply_cursor_mode(mode: u32) void;

pub fn setup(_: std.mem.Allocator, _: std.Io) void {}

pub fn init() input_api.InitError!void {}

pub fn deinit() void {}

pub fn pump() void {
    core.signal_frame_boundary();
}

pub fn apply_cursor_mode(mode: core.CursorMode) void {
    aether_input_apply_cursor_mode(@intFromEnum(mode));
}

pub fn begin_text_input_session(_: *const core.TextInputTarget, _: *const core.TextInputOptions) input_api.TextSessionError!void {}

pub fn end_text_input_session() void {}

export fn aether_input_key(key_code: u32, pressed: bool, repeat: bool, mods_bits: u32) void {
    const key: core.Key = std.enums.fromInt(core.Key, key_code) orelse return;
    const mods = decodeMods(mods_bits);
    if (pressed) {
        core.deliver_key_down(key, mods, repeat);
    } else {
        core.deliver_key_up(key, mods);
    }
}

export fn aether_input_text(ptr: [*]const u8, len: usize) void {
    core.deliver_text(ptr[0..len]);
}

export fn aether_input_mouse_button(button_code: u32, pressed: bool, x: f32, y: f32) void {
    if (button_code > @intFromEnum(core.MouseButton.Middle)) return;
    const button: core.MouseButton = @enumFromInt(button_code);
    core.deliver_mouse_button(button, if (pressed) .pressed else .released, .{ .x = x, .y = y });
}

export fn aether_input_mouse_move(x: f32, y: f32, dx: f32, dy: f32) void {
    core.deliver_mouse_move(.{ .x = x, .y = y }, .{ .x = dx, .y = dy });
}

export fn aether_input_mouse_wheel(dx: f32, dy: f32) void {
    core.deliver_mouse_wheel(.{ .x = dx, .y = dy });
}

export fn aether_input_focus(gained: bool) void {
    core.deliver_focus_change(gained);
}

export fn aether_input_gamepad_button(button_code: u32, pressed: bool) void {
    const button: core.Button = std.enums.fromInt(core.Button, button_code) orelse return;
    core.deliver_gamepad_button(button, if (pressed) .pressed else .released);
}

export fn aether_input_gamepad_axis(axis_code: u32, value: f32) void {
    const axis: core.Axis = std.enums.fromInt(core.Axis, axis_code) orelse return;
    core.deliver_gamepad_axis(axis, value);
}

fn decodeMods(bits: u32) core.ModifierSet {
    var mods: core.ModifierSet = .{};
    if (bits & 0x1 != 0) mods.insert(.shift);
    if (bits & 0x2 != 0) mods.insert(.ctrl);
    if (bits & 0x4 != 0) mods.insert(.alt);
    if (bits & 0x8 != 0) mods.insert(.super);
    return mods;
}
