//! Generic control prompts. The application supplies artwork and wording.
const std = @import("std");
const input = @import("../input/input.zig");
const layout = @import("layout.zig");
const DrawList = @import("DrawList.zig");
const FontBatcher = @import("FontBatcher.zig");
const Rendering = @import("../rendering/rendering.zig");
const TextureRegion = @import("texture_region.zig").TextureRegion;
const Color = @import("Color.zig").Color;

pub const Glyph = struct {
    texture: *const Rendering.Texture,
    region: TextureRegion,
    width: i16,
    height: i16,
    /// Optional label painted over the glyph (for example a keyboard key cap).
    overlay: ?[]const u8 = null,
};
pub const GlyphProvider = struct {
    context: *anyopaque,
    get: *const fn (*anyopaque, input.BindingSource, input.InputMode) ?Glyph,
};
pub const Prompt = struct { chord: []const input.BindingSource, label: []const u8 };
pub const Options = struct {
    origin: layout.Point,
    height: i16 = 16,
    gap: i16 = 8,
    chord_gap: i16 = 2,
    chord_separator: []const u8 = "+",
    glyph_offset_y: i16 = 0,
    text_offset_y: i16 = 0,
    shadow_color: Color = Color.rgba(0, 0, 0, 0),
    label_gap: i16 = 4,
    color: Color = Color.rgba(255, 255, 255, 255),
    mode: input.InputMode = .keyboard_mouse,
    text_scale: u8 = 1,
    spacing: i8 = 0,
};

/// Appends in visual order, copying every label into DrawList storage. Missing
/// artwork falls back to readable binding labels; no vendor is guessed.
/// Use a DrawList clip for a bounded strip. Returns its logical width.
pub fn draw(list: *DrawList, font: *const FontBatcher, provider: ?GlyphProvider, prompts: []const Prompt, options: Options) !i16 {
    if (options.height <= 0 or options.text_scale == 0 or options.gap < 0 or options.chord_gap < 0 or options.label_gap < 0) return error.InvalidBounds;
    var x = options.origin.x;
    for (prompts, 0..) |prompt, prompt_index| {
        if (prompt_index > 0) x = try add(x, options.gap);
        for (prompt.chord, 0..) |source, source_index| {
            if (source_index > 0) {
                x = try add(x, options.chord_gap);
                try text(list, font, options.chord_separator, x, options);
                if (options.chord_separator.len > 0) x = try add(x, try add(font.string_width(options.chord_separator, options.spacing, options.text_scale), options.chord_gap));
            }
            const glyph = if (provider) |p| p.get(p.context, source, options.mode) else null;
            if (glyph) |g| {
                if (g.width < 0 or g.height < 0) return error.InvalidBounds;
                const y = try add(try add(options.origin.y, options.glyph_offset_y), @divTrunc(options.height - g.height, 2));
                try list.add_sprite(.{ .texture = g.texture, .pos_offset = .{ .x = x, .y = y }, .pos_extent = .{ .x = g.width, .y = g.height }, .tex_offset = .{ .x = g.region.x, .y = g.region.y }, .tex_extent = .{ .x = g.region.w, .y = g.region.h }, .color = options.color, .layer = 0 });
                if (g.overlay) |overlay| try text(list, font, overlay, try add(x, @divTrunc(g.width - font.string_width(overlay, options.spacing, options.text_scale), 2)), options);
                x = try add(x, g.width);
            } else {
                var buffer: [64]u8 = undefined;
                const label = try input.display.format_label(&buffer, source, .initEmpty(), .compact);
                try text(list, font, label, x, options);
                x = try add(x, font.string_width(label, options.spacing, options.text_scale));
            }
        }
        if (prompt.chord.len > 0 and prompt.label.len > 0) x = try add(x, options.label_gap);
        try text(list, font, prompt.label, x, options);
        x = try add(x, font.string_width(prompt.label, options.spacing, options.text_scale));
    }
    return std.math.sub(i16, x, options.origin.x) catch error.InvalidBounds;
}
fn add(a: i16, b: i16) error{InvalidBounds}!i16 {
    return std.math.add(i16, a, b) catch error.InvalidBounds;
}
fn text(list: *DrawList, font: *const FontBatcher, label: []const u8, x: i16, options: Options) !void {
    try list.add_text(font, .{ .str = label, .pos_x = x, .pos_y = try add(try add(options.origin.y, options.text_offset_y), @divTrunc(options.height - @as(i16, options.text_scale) * 8, 2)), .color = options.color, .shadow_color = options.shadow_color, .layer = 0, .spacing = options.spacing, .scale = options.text_scale, .reference = .top_left, .origin = .top_left });
}

test "prompt fallback uses input names and copies chord text" {
    var font: FontBatcher = undefined;
    font.style_parser = null;
    font.glyph_widths = @splat(1);
    var list = try DrawList.init(std.testing.allocator, .{});
    defer list.deinit();

    const width = try draw(&list, &font, null, &.{.{ .chord = &.{ .{ .key = .LeftControl }, .{ .key = .A } }, .label = "Select" }}, .{ .origin = .{ .x = 0, .y = 0 } });
    try std.testing.expect(width > 0);
    try std.testing.expectEqualStrings("LCtrl", list.commands[0].value.text.entry.str);
    try std.testing.expectEqualStrings("+", list.commands[1].value.text.entry.str);
    try std.testing.expectEqualStrings("A", list.commands[2].value.text.entry.str);
    try std.testing.expectEqualStrings("Select", list.commands[3].value.text.entry.str);
}
