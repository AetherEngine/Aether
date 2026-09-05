//! ASCII display names; application glyph artwork remains caller supplied.
const std = @import("std");
const data = @import("platform").input_api.data;
const binding = @import("binding.zig");

pub const Style = enum { readable, compact };
pub fn key_name(key: data.Key, style: Style) []const u8 {
    return switch (key) {
        .Num0 => "0",
        .Num1 => "1",
        .Num2 => "2",
        .Num3 => "3",
        .Num4 => "4",
        .Num5 => "5",
        .Num6 => "6",
        .Num7 => "7",
        .Num8 => "8",
        .Num9 => "9",
        .Apostrophe => "'",
        .Comma => ",",
        .Minus => "-",
        .Period => ".",
        .Slash => "/",
        .Semicolon => ";",
        .Equal => "=",
        .LeftBracket => "[",
        .Backslash => "\\",
        .RightBracket => "]",
        .GraveAccent => "`",
        .Escape => if (style == .compact) "Esc" else "Escape",
        .Backspace => if (style == .compact) "Bksp" else "Backspace",
        .Delete => if (style == .compact) "Del" else "Delete",
        .Insert => if (style == .compact) "Ins" else "Insert",
        .PageUp => if (style == .compact) "PgUp" else "Page Up",
        .PageDown => if (style == .compact) "PgDn" else "Page Down",
        .LeftControl => if (style == .compact) "LCtrl" else "Left Ctrl",
        .RightControl => if (style == .compact) "RCtrl" else "Right Ctrl",
        .LeftShift => if (style == .compact) "LShift" else "Left Shift",
        .RightShift => if (style == .compact) "RShift" else "Right Shift",
        .LeftAlt => if (style == .compact) "LAlt" else "Left Alt",
        .RightAlt => if (style == .compact) "RAlt" else "Right Alt",
        .LeftSuper => if (style == .compact) "LSuper" else "Left Super",
        .RightSuper => if (style == .compact) "RSuper" else "Right Super",
        .CapsLock => "Caps Lock",
        .ScrollLock => "Scroll Lock",
        .NumLock => "Num Lock",
        .PrintScreen => "Print Screen",
        .Kp0 => "Num 0",
        .Kp1 => "Num 1",
        .Kp2 => "Num 2",
        .Kp3 => "Num 3",
        .Kp4 => "Num 4",
        .Kp5 => "Num 5",
        .Kp6 => "Num 6",
        .Kp7 => "Num 7",
        .Kp8 => "Num 8",
        .Kp9 => "Num 9",
        .KpDecimal => "Num .",
        .KpDivide => "Num /",
        .KpMultiply => "Num *",
        .KpSubtract => "Num -",
        .KpAdd => "Num +",
        .KpEnter => "Num Enter",
        .KpEqual => "Num =",
        else => @tagName(key),
    };
}
/// Returns NoSpaceLeft instead of silently truncating a control label.
pub fn format_label(buffer: []u8, source: binding.BindingSource, modifiers: data.ModifierSet, style: Style) error{NoSpaceLeft}![]const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    if (modifiers.contains(.ctrl)) writer.writeAll("Ctrl+") catch return error.NoSpaceLeft;
    if (modifiers.contains(.shift)) writer.writeAll("Shift+") catch return error.NoSpaceLeft;
    if (modifiers.contains(.alt)) writer.writeAll("Alt+") catch return error.NoSpaceLeft;
    if (modifiers.contains(.super)) writer.writeAll("Super+") catch return error.NoSpaceLeft;
    switch (source) {
        .key => |key| writer.writeAll(key_name(key, style)) catch return error.NoSpaceLeft,
        .mouse_button => |button| writer.print("Mouse {s}", .{@tagName(button)}) catch return error.NoSpaceLeft,
        .mouse_wheel => |axis| writer.print("Wheel {s}", .{@tagName(axis)}) catch return error.NoSpaceLeft,
        .mouse_delta => |axis| writer.print("Mouse Delta {s}", .{@tagName(axis)}) catch return error.NoSpaceLeft,
        .gamepad_button => |button| writer.print("Pad {s}", .{@tagName(button)}) catch return error.NoSpaceLeft,
        .gamepad_axis => |axis| writer.print("Pad Axis {s}", .{@tagName(axis)}) catch return error.NoSpaceLeft,
    }
    return writer.buffered();
}
test "readable labels retain modifiers and report small output" {
    var buffer: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Page Down", try format_label(&buffer, .{ .key = .PageDown }, .initOne(.ctrl), .readable));
    try std.testing.expectEqualStrings("0", key_name(.Num0, .compact));
    try std.testing.expectError(error.NoSpaceLeft, format_label(buffer[0..2], .{ .key = .Escape }, .initEmpty(), .readable));
}
