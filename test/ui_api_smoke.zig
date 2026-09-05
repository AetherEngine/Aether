//! Compile-only coverage for the public UI/input APIs. The application references
//! both exported probes to force target code generation without running them.
const std = @import("std");
const ae = @import("aether");
const Ui = ae.Ui;
const Input = ae.Core.input;

/// Requires initialized input/font/texture services and runs outside a graphics
/// frame. The output owns uploaded geometry; its registry and textures remain
/// borrowed. The caller must draw and deinitialize it with the usual frame rules.
pub export fn aether_api_smoke_ui_prepare(
    allocator: *const std.mem.Allocator,
    system: *Input.InputSystem,
    font: *const Ui.FontBatcher,
    texture: *const ae.Rendering.Texture,
    registry: *const Ui.CustomRenderable.Registry,
    actions: *const Ui.InputAdapter.Actions,
    provider: *const Ui.GlyphProvider,
    output: *Ui.DrawList.Prepared,
) bool {
    prepare(allocator.*, system, font, texture, registry, actions.*, provider.*, output) catch return false;
    return true;
}

/// Requires a prepared list and an active UI rendering pass with cleared depth.
pub export fn aether_api_smoke_ui_draw(prepared: *Ui.DrawList.Prepared) void {
    prepared.draw();
}

fn prepare(
    allocator: std.mem.Allocator,
    system: *Input.InputSystem,
    font: *const Ui.FontBatcher,
    texture: *const ae.Rendering.Texture,
    registry: *const Ui.CustomRenderable.Registry,
    actions: Ui.InputAdapter.Actions,
    provider: Ui.GlyphProvider,
    output: *Ui.DrawList.Prepared,
) !void {
    var state = try Ui.State.init(allocator, .{ .focusables = 32, .scrolls = 4, .stack_depth = 8 });
    defer state.deinit();

    var list = try Ui.DrawList.init(allocator, .{ .commands = 128, .text_bytes = 4096, .clip_depth = 8 });
    defer list.deinit();

    list.clear();
    var adapter: Ui.InputAdapter = .{};
    adapter.open();
    const frame = adapter.poll(system, actions, 1.0 / 60.0, 1);
    const bounds: Ui.LogicalRect = .{ .x0 = 0, .y0 = 0, .x1 = 320, .y1 = 240 };
    const region: Ui.TextureRegion = .{ .x = 0, .y = 0, .w = 16, .h = 16 };
    const paint: Ui.WidgetStyle.Paint = .{ .image = .{ .texture = texture, .region = region, .sizing = .{ .nine_slice = .{ .left = 2, .right = 2, .top = 2, .bottom = 2 } } } };
    const button_style: Ui.WidgetStyle.Button = .{ .normal = paint, .focused = paint, .active = paint, .disabled = paint };
    var ui = try Ui.Context.begin(&state, &list, .{
        .bounds = bounds,
        .input = frame,
        .font = font,
        .style = .{ .button = button_style, .slider = .{ .track = button_style, .knob = button_style }, .text_field = .{ .background = button_style } },
    });
    try ui.stack(bounds, .{ .padding = .all(4), .gap = 2 });
    std.mem.doNotOptimizeAway(try ui.button(1, "Continue", .{}, true));
    var value: f32 = 0.5;
    std.mem.doNotOptimizeAway(try ui.slider(2, try ui.next(.{}, .{ .x = 100, .y = 20 }), &value, 0, 1, 0.1, true));
    var text: [32]u8 = undefined;
    @memcpy(text[0..4], "Text");
    var length: usize = 4;
    std.mem.doNotOptimizeAway(try ui.text_field(3, try ui.next(.{}, .{ .x = 100, .y = 20 }), &text, &length, true));
    const viewport: Ui.LogicalRect = .{ .x0 = 4, .y0 = 80, .x1 = 316, .y1 = 180 };
    try ui.scroll_list(4, viewport, 180, 12);
    var selected: usize = 0;
    std.mem.doNotOptimizeAway(try ui.selectable_grid(5, viewport, 6, 3, &selected, .{ .context = &selected, .draw = draw_item }, true));
    try ui.end_stack();
    try ui.end_stack();
    try ui.end();
    std.mem.doNotOptimizeAway(state.scroll_offset(4));
    state.reset_scroll(4);
    state.close();

    const first = list.count;
    try list.push_clip(bounds);
    try list.add_region(texture, region, .{ .x0 = 4, .y0 = 184, .x1 = 16, .y1 = 200 }, Ui.Color.rgba(255, 255, 255, 255), 0, .{ .center_elide = .{ .min_w = 2, .max_w = 16 } });
    try list.add_custom(Ui.CustomRenderable.Command.init(.app0, viewport, 0, .reject_bounds, 0, @as(u32, 1)));
    try list.pop_clip();
    try list.offset_range(first, list.count, .{ .x = 0, .y = 1 });
    std.mem.doNotOptimizeAway(try Ui.PromptStrip.draw(&list, font, provider, &.{.{ .chord = &.{.{ .key = .Enter }}, .label = "Accept" }}, .{ .origin = .{ .x = 4, .y = 208 } }));
    var wrapped_bytes: [128]u8 = undefined;
    var lines: [8][]const u8 = undefined;
    std.mem.doNotOptimizeAway(try Ui.TextWrap.wrap(font, "Literal text wrapping\nNext line", .{ .max_width = 80 }, &wrapped_bytes, &lines));

    var label_buffer: [64]u8 = undefined;
    const label = try Input.display.format_label(&label_buffer, .{ .key = .PageDown }, .initOne(.ctrl), .compact);
    std.mem.doNotOptimizeAway(label.len);
    const binding: Input.Binding = .{ .source = .{ .gamepad_axis = .LeftX }, .component = .x, .multiplier = -1, .deadzone = 0.25 };
    std.mem.doNotOptimizeAway(try Input.serialization.decode(try Input.serialization.encode(binding, &label_buffer)));
    std.mem.doNotOptimizeAway(Ui.TextureAtlas.init_grid(16, 16).tile_u(15));
    output.* = try list.prepare(allocator, registry, texture, 320, 240, 1);
}

fn draw_item(_: *anyopaque, ui: *Ui.Context, index: usize, bounds: Ui.LogicalRect, selected: bool) !void {
    _ = index;
    try ui.draw.add_rect(bounds, if (selected) ui.style.focused else ui.style.background, 0);
}
