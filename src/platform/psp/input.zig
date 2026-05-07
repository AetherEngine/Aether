//! PSP-driven input backend. Diffs the controller pad against the
//! previous frame to emit gamepad button edges; emits Lx/Ly axis events
//! every frame the stick is non-zero. Hooks into the system OSK for text
//! input.

const std = @import("std");
const sdk = @import("pspsdk");
const ctrl = sdk.ctrl;

const core = @import("../../core/input/input.zig");
const dialogs = @import("psp_dialogs.zig");

var prev_pad: ctrl.Data = std.mem.zeroes(ctrl.Data);
var have_prev: bool = false;

pub fn setup(_: std.mem.Allocator, _: std.Io) void {
    prev_pad = std.mem.zeroes(ctrl.Data);
    have_prev = false;
}

pub fn init() anyerror!void {
    _ = ctrl.set_sampling_cycle(0);
    _ = ctrl.set_sampling_mode(.analog);
    sdk.extra.utils.enableHBCB();
}

pub fn deinit() void {}

pub fn pump() void {
    var buf: [1]ctrl.Data = undefined;
    ctrl.peek_buffer_positive(&buf) catch return;
    const pad = buf[0];

    diff_buttons(pad);
    diff_axes(pad);

    prev_pad = pad;
    have_prev = true;
    core.signal_frame_boundary();
}

pub fn apply_cursor_mode(_: core.CursorMode) void {}

pub fn begin_text_input_session(target: core.TextInputTarget, options: core.TextInputOptions) anyerror!void {
    // OSK is modal -- runs its own loop and writes the buffer on return.
    var desc_buf: [128]u16 = @splat(0);
    const desc_len = std.unicode.utf8ToUtf16Le(&desc_buf, target.id) catch 0;
    if (desc_len < desc_buf.len) desc_buf[desc_len] = 0;

    const max_chars: usize = if (options.max_bytes) |m| @min(m, 256) else 256;
    var out_buf: [257]u16 = @splat(0);
    const out_slice = out_buf[0 .. max_chars + 1];

    const result = dialogs.showOSK(desc_buf[0..desc_len], out_slice, @intCast(max_chars));

    var utf8_buf: [1024]u8 = undefined;
    var u_len: usize = 0;
    var i: usize = 0;
    while (i < out_slice.len and out_slice[i] != 0) : (i += 1) {
        const code: u21 = out_slice[i];
        const enc = std.unicode.utf8Encode(code, utf8_buf[u_len..]) catch break;
        u_len += enc;
    }

    const status: core.TextInputStatus = if (result == 0) .submitted else .cancelled;
    core.write_text_session_buffer(utf8_buf[0..u_len], status);
}

pub fn end_text_input_session() void {}

// -- helpers -----------------------------------------------------------------

fn buttons_eq_for(field: []const u8, prev: anytype, now: anytype) bool {
    return @field(prev, field) == @field(now, field);
}

fn diff_buttons(now: ctrl.Data) void {
    const Pair = struct { field: []const u8, button: core.Button };
    const map = [_]Pair{
        .{ .field = "cross", .button = .A },
        .{ .field = "circle", .button = .B },
        .{ .field = "square", .button = .X },
        .{ .field = "triangle", .button = .Y },
        .{ .field = "l_trigger", .button = .LButton },
        .{ .field = "r_trigger", .button = .RButton },
        .{ .field = "select", .button = .Back },
        .{ .field = "start", .button = .Start },
        .{ .field = "home", .button = .Guide },
        .{ .field = "up", .button = .DpadUp },
        .{ .field = "right", .button = .DpadRight },
        .{ .field = "down", .button = .DpadDown },
        .{ .field = "left", .button = .DpadLeft },
    };
    inline for (map) |entry| {
        const now_bit = @field(now.buttons, entry.field);
        const prev_bit = if (have_prev) @field(prev_pad.buttons, entry.field) else 0;
        if (now_bit != prev_bit) {
            const edge: core.ButtonState = if (now_bit == 1) .pressed else .released;
            core.deliver_gamepad_button(entry.button, edge);
        }
    }
}

fn diff_axes(now: ctrl.Data) void {
    const lx = normalize(now.Lx);
    const ly = normalize(now.Ly);
    const prev_lx: f32 = if (have_prev) normalize(prev_pad.Lx) else 0;
    const prev_ly: f32 = if (have_prev) normalize(prev_pad.Ly) else 0;
    if (lx != 0 or prev_lx != 0) core.deliver_gamepad_axis(.LeftX, lx);
    if (ly != 0 or prev_ly != 0) core.deliver_gamepad_axis(.LeftY, ly);
}

fn normalize(raw: u8) f32 {
    return (@as(f32, @floatFromInt(raw)) - 128.0) / 128.0;
}
