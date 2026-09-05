//! Bounded byte-font wrapping with caller-owned measurement and styling.
//! Spaces at soft breaks are discarded; explicit newlines preserve empty lines.
//! Oversized words split at glyph boundaries. A single oversized glyph is emitted
//! and reported via `overflowed_width`. Optional zero-width controls stay whole.
const std = @import("std");

pub const Options = struct {
    max_width: i16,
    spacing: i8 = 0,
    scale: u8 = 1,
    /// Optional application token recognizer, matching the font's measurement.
    /// Return a zero-width control's byte length, or zero for a literal glyph.
    /// Continuation styling across output lines belongs to the caller.
    control_length: ?*const fn ([]const u8) usize = null,
};
pub const Result = struct {
    line_count: usize = 0,
    bytes_used: usize = 0,
    consumed: usize = 0,
    truncated: bool = false,
    overflowed_width: bool = false,
};

/// `lines` borrows `buffer`. On exhaustion only complete lines are published;
/// `consumed` identifies the input prefix represented by those lines. The font
/// may be FontBatcher or a compatible `fit_width` implementation.
pub fn wrap(font: anytype, text: []const u8, options: Options, buffer: []u8, lines: [][]const u8) error{InvalidOptions}!Result {
    if (options.scale == 0 or options.max_width <= 0) return error.InvalidOptions;
    var result: Result = .{};
    var pending_empty = false;
    while (result.consumed < text.len or pending_empty) {
        if (result.line_count == lines.len) {
            result.truncated = true;
            break;
        }
        const start = result.consumed;
        var from = start;
        while (from < text.len and text[from] == ' ') : (from += 1) {}
        if (from == text.len and !pending_empty) {
            result.consumed = from;
            break;
        }
        const newline = std.mem.indexOfScalarPos(u8, text, from, '\n') orelse text.len;
        const input = text[from..newline];
        var end = font.fit_width(input, options.max_width, options.spacing, options.scale);
        var overflow = false;
        var next = from + end;
        if (end < input.len) {
            if (end == 0 or only_controls(input[0..end], options)) {
                end = first_glyph_end(input, options);
                next = from + end;
                overflow = true;
            } else if (last_space(input[0..end], options)) |space| {
                if (space > 0) {
                    end = space;
                    next = from + space + 1;
                }
            }
        } else {
            next = if (newline < text.len) newline + 1 else newline;
        }
        const line = std.mem.trimEnd(u8, input[0..end], " ");
        if (line.len > buffer.len - result.bytes_used) {
            result.truncated = true;
            break;
        }
        const output = buffer[result.bytes_used..][0..line.len];
        @memcpy(output, line);
        lines[result.line_count] = output;
        result.bytes_used += output.len;
        result.line_count += 1;
        result.consumed = next;
        result.overflowed_width = result.overflowed_width or overflow;
        if (pending_empty) break;
        pending_empty = newline < text.len and next == text.len;
    }
    return result;
}

fn control_length(text: []const u8, options: Options) usize {
    const recognize = options.control_length orelse return 0;
    const length = recognize(text);
    return if (length <= text.len) length else 0;
}
fn only_controls(text: []const u8, options: Options) bool {
    var i: usize = 0;
    while (i < text.len) {
        const length = control_length(text[i..], options);
        if (length == 0) return false;
        i += length;
    }
    return true;
}
fn first_glyph_end(text: []const u8, options: Options) usize {
    var i: usize = 0;
    while (i < text.len) {
        const length = control_length(text[i..], options);
        if (length == 0) break;
        i += length;
    }
    return @min(i + 1, text.len);
}
fn last_space(text: []const u8, options: Options) ?usize {
    var result: ?usize = null;
    var i: usize = 0;
    while (i < text.len) {
        const length = control_length(text[i..], options);
        if (length != 0) {
            i += length;
        } else {
            if (text[i] == ' ') result = i;
            i += 1;
        }
    }
    return result;
}
const TestFont = struct {
    fn fit_width(_: TestFont, text: []const u8, width: i16, spacing: i8, scale: u8) usize {
        var w: i16 = 0;
        for (text, 0..) |_, i| {
            const next = w + @as(i16, scale) + (if (i > 0) @as(i16, spacing) * scale else 0);
            if (next > width) return i;
            w = next;
        }
        return text.len;
    }
};
test "wrapping preserves literal ampersands newlines scale and oversized words" {
    var storage: [128]u8 = undefined;
    var lines: [8][]const u8 = undefined;
    const result = try wrap(TestFont{}, "&c hello world\n\nabc\n", .{ .max_width = 5 }, &storage, &lines);
    try std.testing.expectEqual(6, result.line_count);
    for ([_][]const u8{ "&c", "hello", "world", "", "abc", "" }, lines[0..6]) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    const scaled = try wrap(TestFont{}, "abc", .{ .max_width = 1, .scale = 2 }, &storage, &lines);
    try std.testing.expectEqual(3, scaled.line_count);
    try std.testing.expect(scaled.overflowed_width);
}
test "wrapping reports exhaustion without publishing partial lines" {
    var storage: [3]u8 = undefined;
    var lines: [4][]const u8 = undefined;
    const result = try wrap(TestFont{}, "&cab", .{ .max_width = 2 }, &storage, &lines);
    try std.testing.expect(result.truncated);
    try std.testing.expectEqual(2, result.consumed);
    try std.testing.expectEqualStrings("&c", lines[0]);
    const empty = try wrap(TestFont{}, "abc", .{ .max_width = 2 }, &storage, lines[0..0]);
    try std.testing.expect(empty.truncated);
    try std.testing.expectEqual(0, empty.consumed);
}

test "wrapping preserves caller controls with internal spaces and oversized glyphs" {
    const FontBatcher = @import("FontBatcher.zig");
    const Controls = struct {
        fn parse(text: []const u8) ?FontBatcher.StyleControl {
            return if (std.mem.startsWith(u8, text, "<ink red>")) .{ .length = 9 } else null;
        }
        fn length(text: []const u8) usize {
            return if (parse(text)) |control| control.length else 0;
        }
    };
    var font: FontBatcher = undefined;
    font.glyph_widths = @splat(2);
    font.style_parser = Controls.parse;
    var storage: [32]u8 = undefined;
    var lines: [4][]const u8 = undefined;
    const result = try wrap(&font, "<ink red>AB", .{ .max_width = 1, .control_length = Controls.length }, &storage, &lines);
    try std.testing.expectEqual(2, result.line_count);
    try std.testing.expect(result.overflowed_width);
    try std.testing.expectEqualStrings("<ink red>A", lines[0]);
    try std.testing.expectEqualStrings("B", lines[1]);
    const too_small = try wrap(&font, "<ink red>A", .{ .max_width = 1, .control_length = Controls.length }, storage[0..9], &lines);
    try std.testing.expect(too_small.truncated);
    try std.testing.expectEqual(0, too_small.consumed);
}
