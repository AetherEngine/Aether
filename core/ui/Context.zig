//! Immediate-mode widgets over DrawList. One State belongs to one surface and
//! must outlive its text session. IDs are caller-chosen, stable, and unique per
//! frame. End every successful begin; call State.close before destroying a menu.
const std = @import("std");
const layout = @import("layout.zig");
const DrawList = @import("DrawList.zig");
const FontBatcher = @import("FontBatcher.zig");
const Color = @import("Color.zig").Color;
const input_api = @import("../input/input.zig");
const InputAdapter = @import("InputAdapter.zig");
const Context = @This();
const WidgetStyle = @import("WidgetStyle.zig");
pub const WidgetId = u64;
pub const Axis = enum { horizontal, vertical };
pub const Size = union(enum) { fixed: i16, content, fill };
pub const Box = struct { width: Size = .fill, height: Size = .content };
pub const Padding = struct {
    left: i16 = 0,
    right: i16 = 0,
    top: i16 = 0,
    bottom: i16 = 0,
    pub fn all(amount: i16) Padding {
        return .{ .left = amount, .right = amount, .top = amount, .bottom = amount };
    }
};
pub const Style = struct {
    button: ?WidgetStyle.Button = null,
    slider: ?WidgetStyle.Slider = null,
    text_field: ?WidgetStyle.TextField = null,
    background: Color = Color.rgba(45, 45, 45, 255),
    focused: Color = Color.rgba(75, 85, 110, 255),
    active: Color = Color.rgba(95, 110, 145, 255),
    disabled: Color = Color.rgba(35, 35, 35, 255),
    foreground: Color = Color.rgba(255, 255, 255, 255),
    disabled_text: Color = Color.rgba(140, 140, 140, 255),
    shadow: Color = Color.rgba(0, 0, 0, 0),
    height: i16 = 20,
    padding: i16 = 4,
    spacing: i8 = 0,
    text_scale: u8 = 1,
    knob_width: i16 = 6,
};
pub const Limits = struct { focusables: usize = 128, scrolls: usize = 16, stack_depth: usize = 16 };
pub const Error = DrawList.Error || error{ FocusCapacity, ScrollCapacity, StackCapacity, StackUnderflow, UnclosedStack, DuplicateWidget, InvalidValue, MissingInputSystem };
pub const Kind = enum { button, slider, text_field, grid };
const Focusable = struct { id: WidgetId, bounds: layout.LogicalRect, kind: Kind, scroll_id: ?WidgetId, clip: ?layout.LogicalRect = null };
const Scroll = struct { id: WidgetId, offset: i16 = 0, viewport: layout.LogicalRect, content_height: i16, wheel_step: i16 = 22, geometry: ?struct { first: Mark, last: Mark } = null };
const Scope = struct { bounds: layout.LogicalRect, axis: Axis, gap: i16, cursor: i16 = 0, clip: bool = false, scroll_id: ?WidgetId = null };

pub const State = struct {
    allocator: std.mem.Allocator,
    focused: ?WidgetId = null,
    hovered: ?WidgetId = null,
    captured_via_click: bool = false,
    seed_focus: bool = true,
    captured: ?WidgetId = null,
    active_text: ?WidgetId = null,
    text_system: ?*input_api.InputSystem = null,
    text_target: [16]u8 = undefined,
    focusables: [2][]Focusable,
    focus_count: [2]usize = .{ 0, 0 },
    current: u1 = 0,
    scrolls: []Scroll,
    scroll_count: usize = 0,
    scopes: []Scope,
    depth: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) !State {
        const first = try allocator.alloc(Focusable, limits.focusables);
        errdefer allocator.free(first);
        const second = try allocator.alloc(Focusable, limits.focusables);
        errdefer allocator.free(second);
        const scrolls = try allocator.alloc(Scroll, limits.scrolls);
        errdefer allocator.free(scrolls);
        return .{ .allocator = allocator, .focusables = .{ first, second }, .scrolls = scrolls, .scopes = try allocator.alloc(Scope, limits.stack_depth) };
    }
    pub fn deinit(self: *State) void {
        self.close();
        self.allocator.free(self.focusables[0]);
        self.allocator.free(self.focusables[1]);
        self.allocator.free(self.scrolls);
        self.allocator.free(self.scopes);
        self.* = undefined;
    }
    /// Cancels only the text session attached by this surface, never another
    /// application's session. The attached InputSystem must still be alive.
    pub fn close(self: *State) void {
        self.cancel_text();
        self.focused = null;
        self.captured = null;
    }
    pub fn cancel_text(self: *State) void {
        if (self.text_system) |system| {
            if (system.current_text_session()) |session| {
                if (self.owns_session(session) and !session.is_terminal()) system.cancel_text() catch {};
            }
        }
        self.active_text = null;
        self.text_system = null;
    }
    fn owns_session(self: *const State, session: *const input_api.TextInputSession) bool {
        return self.active_text != null and session.target.id.ptr == &self.text_target;
    }
    pub fn scroll_offset(self: *const State, id: WidgetId) i16 {
        for (self.scrolls[0..self.scroll_count]) |scroll| if (scroll.id == id) return scroll.offset;
        return 0;
    }
    pub fn reset_scroll(self: *State, id: WidgetId) void {
        for (self.scrolls[0..self.scroll_count]) |*scroll| if (scroll.id == id) {
            scroll.offset = 0;
            return;
        };
    }
};
pub const Options = struct {
    bounds: layout.LogicalRect,
    input: InputAdapter.Frame = .{},
    font: ?*const FontBatcher = null,
    style: Style = .{},
    /// Replay emits current visuals/layout without consuming input or capture.
    replay: bool = false,
    /// Use last completed layout for hit testing during deferred composition.
    deferred_hit_test: bool = false,
    pointer_activation: enum { press, release } = .release,
    slider_capture: bool = false,
    paint: bool = true,
    live_text: bool = false,
    text_events: bool = false,
};
state: *State,
draw: *DrawList,
frame: InputAdapter.Frame,
font: ?*const FontBatcher,
style: Style,
options: Options,
confirm_claimed: bool = false,
pointer_claimed: bool = false,
cancel_consumed: bool = false,
cancelled_text: ?WidgetId = null,

pub fn begin(state: *State, draw: *DrawList, options: Options) Error!Context {
    if (state.scopes.len == 0) return error.StackCapacity;
    try validate_rect(options.bounds);
    if (options.bounds.x1 < options.bounds.x0 or options.bounds.y1 < options.bounds.y0 or options.style.height < 0 or options.style.padding < 0 or options.style.text_scale == 0) return error.InvalidBounds;
    var self: Context = .{ .state = state, .draw = draw, .frame = options.input, .font = options.font, .style = options.style, .options = options };
    state.current ^= 1;
    state.focus_count[state.current] = 0;
    state.scopes[0] = .{ .bounds = options.bounds, .axis = .vertical, .gap = 0 };
    state.depth = 1;
    if (options.replay) self.frame = .{};
    if (!options.replay) {
        state.hovered = null;
        if (self.frame.pointer) |pointer| for (state.focusables[state.current ^ 1][0..state.focus_count[state.current ^ 1]]) |item| {
            if (layout.intersection(item.bounds, item.clip).contains(pointer.x, pointer.y)) state.hovered = item.id;
        };
        if (options.text_events) if (state.text_system) |system| if (system.current_text_session()) |session| {
            if (state.owns_session(session) and session.status == .active) for (system.frame_events()) |event| switch (event.kind) {
                .key_down => |key| {
                    if (key.key == .Backspace) {
                        const edit = @constCast(session);
                        if (edit.buffer.items.len > 0) {
                            var at = edit.buffer.items.len - 1;
                            while (at > 0 and (edit.buffer.items[at] & 0xc0) == 0x80) : (at -= 1) {}
                            edit.buffer.items.len = at;
                        }
                    } else if (key.key == .Enter and !key.is_repeat) {
                        system.submit_text() catch {};
                        self.confirm_claimed = true;
                    }
                },
                .gamepad_button_down => |event_button| if (event_button.button == .A) {
                    system.submit_text() catch {};
                    self.confirm_claimed = true;
                },
                else => {},
            };
        };
        if (self.frame.cancel and state.captured != null) {
            state.captured = null;
            self.frame.cancel = false;
            self.cancel_consumed = true;
        }
        if (options.deferred_hit_test) if (self.frame.pointer) |pointer| for (state.scrolls[0..state.scroll_count]) |*scroll| {
            if (scroll.viewport.contains(pointer.x, pointer.y)) {
                scroll.offset = @intCast(std.math.clamp(@as(i32, scroll.offset) - @as(i32, self.frame.wheel) * scroll.wheel_step, 0, @max(0, @as(i32, scroll.content_height) - scroll.viewport.height())));
                self.frame.wheel = 0;
            }
        };
    }
    if (self.frame.cancel and state.active_text != null) {
        self.cancelled_text = state.active_text;
        state.cancel_text();
        self.cancel_consumed = true;
    }
    if (self.frame.direction) |direction| self.navigate(direction, false);
    for (state.scrolls[0..state.scroll_count]) |*scroll| scroll.geometry = null;
    return self;
}
pub fn end(self: *Context) Error!void {
    if (self.state.depth != 1) return error.UnclosedStack;
    if (!self.has_current(self.state.focused)) self.state.focused = if (self.state.seed_focus and self.state.focus_count[self.state.current] > 0) self.state.focusables[self.state.current][0].id else null;
    if (!self.options.replay and (!self.has_current(self.state.captured) or (self.state.captured_via_click and (self.frame.pointer_released or !self.frame.pointer_down)))) self.state.captured = null;
    if (self.state.active_text != null and !self.has_current(self.state.active_text)) self.state.cancel_text();
    self.state.depth = 0;
}
fn has_current(self: *const Context, id: ?WidgetId) bool {
    const wanted = id orelse return false;
    for (self.state.focusables[self.state.current][0..self.state.focus_count[self.state.current]]) |item| if (item.id == wanted) return true;
    return false;
}

pub const StackOptions = struct { axis: Axis = .vertical, padding: Padding = .{}, gap: i16 = 0 };
/// Stack children use intrinsic dimensions for content, fixed logical pixels,
/// or the space remaining at the call for fill. Explicit bounds keep layout
/// deterministic without requiring a second application evaluation pass.
pub fn stack(self: *Context, bounds: layout.LogicalRect, options: StackOptions) Error!void {
    try validate_rect(bounds);
    if (self.state.depth == self.state.scopes.len) return error.StackCapacity;
    if (options.gap < 0 or options.padding.left < 0 or options.padding.right < 0 or options.padding.top < 0 or options.padding.bottom < 0) return error.InvalidBounds;
    const inner: layout.LogicalRect = .{ .x0 = try add(bounds.x0, options.padding.left), .y0 = try add(bounds.y0, options.padding.top), .x1 = try add(bounds.x1, -options.padding.right), .y1 = try add(bounds.y1, -options.padding.bottom) };
    if (inner.x1 < inner.x0 or inner.y1 < inner.y0) return error.InvalidBounds;
    self.state.scopes[self.state.depth] = .{ .bounds = inner, .axis = options.axis, .gap = options.gap, .scroll_id = self.state.scopes[self.state.depth - 1].scroll_id };
    self.state.depth += 1;
}
pub fn end_stack(self: *Context) Error!void {
    if (self.state.depth <= 1) return error.StackUnderflow;
    if (self.state.scopes[self.state.depth - 1].clip) try self.draw.pop_clip();
    self.state.depth -= 1;
}
pub fn next(self: *Context, box: Box, intrinsic: layout.Point) Error!layout.LogicalRect {
    const scope = &self.state.scopes[self.state.depth - 1];
    const left: i16 = if (scope.axis == .horizontal) scope.cursor else 0;
    const top: i16 = if (scope.axis == .vertical) scope.cursor else 0;
    const w = try dimension(box.width, intrinsic.x, @max(0, scope.bounds.width() - left));
    const h = try dimension(box.height, intrinsic.y, @max(0, scope.bounds.height() - top));
    const x = try add(scope.bounds.x0, left);
    const y = try add(scope.bounds.y0, top);
    const rect: layout.LogicalRect = .{ .x0 = x, .y0 = y, .x1 = try add(x, w), .y1 = try add(y, h) };
    scope.cursor = try add(scope.cursor, try add(if (scope.axis == .horizontal) w else h, scope.gap));
    return rect;
}
fn validate_rect(rect: layout.LogicalRect) Error!void {
    if (rect.x1 < rect.x0 or rect.y1 < rect.y0 or @as(i32, rect.x1) - rect.x0 > 32767 or @as(i32, rect.y1) - rect.y0 > 32767) return error.InvalidBounds;
}
fn dimension(size: Size, intrinsic: i16, remaining: i16) Error!i16 {
    const value = switch (size) {
        .fixed => |fixed| fixed,
        .content => intrinsic,
        .fill => remaining,
    };
    if (value < 0) return error.InvalidBounds;
    return value;
}
fn add(a: i16, b: i16) Error!i16 {
    return std.math.add(i16, a, b) catch error.InvalidBounds;
}

/// A scroll viewport clips all child commands. Positive wheel moves toward the
/// beginning. Content height and scroll state are bounded to logical i16 pixels.
pub fn scroll_list(self: *Context, id: WidgetId, viewport: layout.LogicalRect, content_height: i16, wheel_step: i16) Error!void {
    try validate_rect(viewport);
    if (content_height < 0 or wheel_step < 0 or viewport.x1 < viewport.x0 or viewport.y1 < viewport.y0) return error.InvalidBounds;
    if (self.state.depth == self.state.scopes.len) return error.StackCapacity;
    var found: ?*Scroll = null;
    for (self.state.scrolls[0..self.state.scroll_count]) |*scroll| if (scroll.id == id) {
        found = scroll;
        break;
    };
    if (found == null) {
        if (self.state.scroll_count == self.state.scrolls.len) return error.ScrollCapacity;
        found = &self.state.scrolls[self.state.scroll_count];
        found.?.* = .{ .id = id, .viewport = viewport, .content_height = content_height };
        self.state.scroll_count += 1;
    }
    const scroll = found.?;
    scroll.viewport = viewport;
    scroll.content_height = content_height;
    scroll.wheel_step = wheel_step;
    const maximum = @max(0, @as(i32, content_height) - viewport.height());
    var offset: i32 = scroll.offset;
    if (self.frame.pointer) |pointer| if (viewport.contains(pointer.x, pointer.y)) {
        offset -= @as(i32, self.frame.wheel) * wheel_step;
        self.frame.wheel = 0;
    };
    scroll.offset = @intCast(std.math.clamp(offset, 0, maximum));
    var bounds = viewport;
    bounds.y0 = try add(viewport.y0, -scroll.offset);
    bounds.y1 = try add(bounds.y0, content_height);
    try self.draw.push_clip(viewport);
    self.state.scopes[self.state.depth] = .{ .bounds = bounds, .axis = .vertical, .gap = 0, .clip = true, .scroll_id = id };
    self.state.depth += 1;
}

pub const Interaction = struct { hovered: bool = false, focused: bool = false, activated: bool = false };
pub fn interact(self: *Context, id: WidgetId, rect: layout.LogicalRect, kind: Kind, enabled: bool) Error!Interaction {
    try validate_rect(rect);
    if (!enabled) return .{};
    const current = self.state.current;
    for (self.state.focusables[current][0..self.state.focus_count[current]]) |item| if (item.id == id) return error.DuplicateWidget;
    if (self.state.focus_count[current] == self.state.focusables[current].len) return error.FocusCapacity;
    const scope = self.state.scopes[self.state.depth - 1];
    self.state.focusables[current][self.state.focus_count[current]] = .{ .id = id, .bounds = rect, .kind = kind, .scroll_id = scope.scroll_id, .clip = self.draw.current_clip() };
    self.state.focus_count[current] += 1;
    const hit = self.hit_bounds(id, rect);
    const visible = if (self.options.deferred_hit_test) self.previous_visible(id) orelse layout.LogicalRect{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 } else layout.intersection(hit, self.draw.current_clip());
    var result: Interaction = .{};
    if (self.frame.pointer) |pointer| result.hovered = visible.contains(pointer.x, pointer.y);
    if (result.hovered) self.state.hovered = id;
    if (self.options.replay) return .{ .hovered = self.state.hovered == id, .focused = self.state.focused == id };
    if (result.hovered and self.frame.pointer_moved) self.state.focused = id;
    if (result.hovered and self.frame.pointer_pressed and !self.pointer_claimed) {
        if (self.state.active_text != id) self.state.cancel_text();
        self.state.captured = id;
        self.state.captured_via_click = true;
        result.activated = self.options.pointer_activation == .press;
        if (result.activated and kind != .slider) self.state.captured = null;
        self.state.focused = id;
        self.pointer_claimed = true;
    }
    result.focused = self.state.focused == id;
    if (self.state.captured == id and self.frame.pointer_released) {
        result.activated = result.hovered and self.options.pointer_activation == .release;
        self.state.captured = null;
    }
    if (result.focused and self.frame.confirm and !self.confirm_claimed and self.state.active_text == null) {
        result.activated = true;
        self.confirm_claimed = true;
        if (kind == .slider and self.options.slider_capture) {
            self.state.captured = id;
            self.state.captured_via_click = false;
        }
    }
    return result;
}
/// Previous final geometry is useful to application-owned widget renderers.
pub fn hit_bounds(self: *const Context, id: WidgetId, fallback: layout.LogicalRect) layout.LogicalRect {
    if (self.options.deferred_hit_test) for (self.state.focusables[self.state.current ^ 1][0..self.state.focus_count[self.state.current ^ 1]]) |item| if (item.id == id) return item.bounds;
    return fallback;
}
fn previous_visible(self: *const Context, id: WidgetId) ?layout.LogicalRect {
    for (self.state.focusables[self.state.current ^ 1][0..self.state.focus_count[self.state.current ^ 1]]) |item| if (item.id == id) return layout.intersection(item.bounds, item.clip);
    return null;
}
pub const Mark = struct { draw: usize, focus: usize, scroll: usize };
pub fn mark(self: *const Context) Mark {
    return .{ .draw = self.draw.count, .focus = self.state.focus_count[self.state.current], .scroll = self.state.scroll_count };
}
/// Clips completed deferred children after their local alignment is resolved.
/// Applying the viewport here keeps it fixed while children align inside it.
pub fn clip_range(self: *Context, first: Mark, last: Mark, bounds: layout.LogicalRect) Error!void {
    try validate_rect(bounds);
    if (first.draw > last.draw or last.draw > self.draw.count or first.focus > last.focus or last.focus > self.state.focus_count[self.state.current]) return error.InvalidRange;
    for (self.draw.commands[first.draw..last.draw]) |*command| {
        command.clip = layout.intersection(bounds, command.clip);
        if (command.value == .text) command.value.text.entry.clip = layout.intersection(bounds, command.value.text.entry.clip);
    }
    for (self.state.focusables[self.state.current][first.focus..last.focus]) |*item| item.clip = layout.intersection(bounds, item.clip);
}
/// Moves completed deferred geometry and matching interaction rectangles together.
pub fn translate(self: *Context, first: Mark, last: Mark, offset: layout.Point) Error!void {
    try self.draw.offset_range(first.draw, last.draw, offset);
    for (self.state.focusables[self.state.current][first.focus..last.focus]) |*item| {
        item.bounds.x0 = try add(item.bounds.x0, offset.x);
        item.bounds.x1 = try add(item.bounds.x1, offset.x);
        item.bounds.y0 = try add(item.bounds.y0, offset.y);
        item.bounds.y1 = try add(item.bounds.y1, offset.y);
        if (item.clip) |*clip| {
            clip.x0 = try add(clip.x0, offset.x);
            clip.x1 = try add(clip.x1, offset.x);
            clip.y0 = try add(clip.y0, offset.y);
            clip.y1 = try add(clip.y1, offset.y);
        }
    }
    // Scroll entries are stable across frames; translate those whose children
    // occur in this range, rather than relying on insertion indices.
    for (self.state.scrolls[0..self.state.scroll_count]) |*scroll| {
        var owns = false;
        if (scroll.geometry) |geometry| {
            owns = geometry.first.draw >= first.draw and geometry.last.draw <= last.draw and geometry.first.focus >= first.focus and geometry.last.focus <= last.focus;
        } else for (self.state.focusables[self.state.current][first.focus..last.focus]) |item| if (item.scroll_id == scroll.id) {
            owns = true;
            break;
        };
        if (owns) {
            scroll.viewport.x0 = try add(scroll.viewport.x0, offset.x);
            scroll.viewport.x1 = try add(scroll.viewport.x1, offset.x);
            scroll.viewport.y0 = try add(scroll.viewport.y0, offset.y);
            scroll.viewport.y1 = try add(scroll.viewport.y1, offset.y);
        }
    }
}
pub fn register_scroll(self: *Context, id: WidgetId, viewport: layout.LogicalRect, content_height: i16) Error!void {
    for (self.state.scrolls[0..self.state.scroll_count]) |*scroll| if (scroll.id == id) {
        scroll.viewport = viewport;
        scroll.content_height = content_height;
        scroll.offset = @min(scroll.offset, @max(0, content_height - viewport.height()));
        return;
    };
    if (self.state.scroll_count == self.state.scrolls.len) return error.ScrollCapacity;
    self.state.scrolls[self.state.scroll_count] = .{ .id = id, .viewport = viewport, .content_height = content_height };
    self.state.scroll_count += 1;
}
fn background(self: *Context, id: WidgetId, rect: layout.LogicalRect, enabled: bool, interaction: Interaction, theme: ?WidgetStyle.Button) Error!void {
    if (!self.options.paint) return;
    if (theme) |button_theme| return button_theme.paint(enabled, interaction.hovered or interaction.focused, self.state.captured == id or self.state.active_text == id).draw(self.draw, rect);
    try self.draw.add_rect(rect, if (!enabled) self.style.disabled else if (self.state.captured == id or self.state.active_text == id) self.style.active else if (interaction.hovered or interaction.focused) self.style.focused else self.style.background, 0);
}
pub fn label(self: *Context, rect: layout.LogicalRect, text: []const u8, color: Color) Error!void {
    try validate_rect(rect);
    if (!self.options.paint) return;
    const font = self.font orelse return;
    if (text.len == 0) return;
    const x = try add(rect.x0, self.style.padding);
    const y = try add(rect.y0, @divTrunc(rect.height() - @as(i16, self.style.text_scale) * 8, 2));
    try self.draw.add_text(font, .{ .str = text, .color = color, .shadow_color = self.style.shadow, .pos_x = x, .pos_y = y, .spacing = self.style.spacing, .scale = self.style.text_scale, .layer = 0, .reference = .top_left, .origin = .top_left, .clip = rect });
}
pub fn button(self: *Context, id: WidgetId, text: []const u8, box: Box, enabled: bool) Error!bool {
    const width = if (self.font) |font| try add(font.string_width(text, self.style.spacing, self.style.text_scale), try add(self.style.padding, self.style.padding)) else 0;
    return self.button_at(id, text, try self.next(box, .{ .x = width, .y = self.style.height }), enabled);
}
pub fn button_at(self: *Context, id: WidgetId, text: []const u8, rect: layout.LogicalRect, enabled: bool) Error!bool {
    const interaction = try self.interact(id, rect, .button, enabled);
    try self.background(id, rect, enabled, interaction, self.style.button);
    try self.label(rect, text, if (enabled) self.style.foreground else self.style.disabled_text);
    return interaction.activated;
}
/// Returns true when value changes. The value is clamped and controller changes
/// use step; pointer capture remains attached until release outside the widget.
pub fn slider(self: *Context, id: WidgetId, rect: layout.LogicalRect, value: *f32, min: f32, max: f32, step: f32, enabled: bool) Error!bool {
    if (!std.math.isFinite(min) or !std.math.isFinite(max) or !std.math.isFinite(step) or !std.math.isFinite(value.*) or min >= max or step <= 0 or rect.x1 <= rect.x0) return error.InvalidValue;
    const previous = value.*;
    const interaction = try self.interact(id, rect, .slider, enabled);
    value.* = std.math.clamp(value.*, min, max);
    const hit = self.hit_bounds(id, rect);
    if (!self.options.replay and enabled and self.state.captured == id and self.state.captured_via_click) if (self.frame.pointer) |pointer| {
        value.* = min + (max - min) * std.math.clamp(@as(f32, @floatFromInt(@as(i32, pointer.x) - hit.x0)) / @as(f32, @floatFromInt(hit.width())), 0, 1);
    };
    if (enabled and interaction.focused and (!self.options.slider_capture or self.state.captured == id)) if (self.frame.direction) |direction| {
        if (direction == .left) value.* = @max(min, value.* - step);
        if (direction == .right) value.* = @min(max, value.* + step);
    };
    try self.background(id, rect, enabled, interaction, if (self.style.slider) |theme| theme.track else null);
    if (!self.options.paint) return previous != value.*;
    const knob_width = @min(rect.width(), @max(1, self.style.knob_width));
    const x: i16 = @intCast(@as(i32, rect.x0) + @as(i32, @intFromFloat((value.* - min) / (max - min) * @as(f32, @floatFromInt(rect.width() - knob_width)))));
    const knob: layout.LogicalRect = .{ .x0 = x, .y0 = rect.y0, .x1 = x + knob_width, .y1 = rect.y1 };
    if (self.style.slider) |theme| try theme.knob.paint(enabled, interaction.focused or interaction.hovered, self.state.captured == id).draw(self.draw, knob) else try self.draw.add_rect(knob, self.style.foreground, 0);
    return previous != value.*;
}
pub const TextResult = struct { changed: bool = false, submitted: bool = false, cancelled: bool = false, editing: bool = false };
/// Edits in InputSystem's bounded session buffer and copies into caller storage
/// only on submit. Cancellation preserves the previous value. No borrowed caller
/// text survives this call; State's session target must remain at a stable address.
pub fn text_field(self: *Context, id: WidgetId, rect: layout.LogicalRect, buffer: []u8, length: *usize, enabled: bool) !TextResult {
    if (length.* > buffer.len) return error.InvalidValue;
    const interaction = try self.interact(id, rect, .text_field, enabled);
    var result: TextResult = .{ .cancelled = self.cancelled_text == id };
    if (!enabled and self.state.active_text == id) self.state.cancel_text();
    if (interaction.activated and self.state.active_text != id) {
        const system = self.frame.input_system orelse return error.MissingInputSystem;
        self.state.cancel_text();
        _ = try std.fmt.bufPrint(&self.state.text_target, "{x:0>16}", .{id});
        _ = try system.begin_text_input(&.{ .id = &self.state.text_target }, &.{ .initial = buffer[0..length.*], .max_bytes = buffer.len });
        self.state.active_text = id;
        self.state.text_system = system;
    }
    var display_text: []const u8 = buffer[0..length.*];
    if (self.state.active_text == id) {
        const system = self.state.text_system.?;
        if (system.current_text_session()) |session| {
            if (!self.state.owns_session(session)) self.state.cancel_text() else switch (session.status) {
                .active, .suspended => {
                    display_text = session.buffer.items;
                    if (self.options.live_text and !self.options.replay) {
                        const take = @min(buffer.len, display_text.len);
                        result.changed = !std.mem.eql(u8, buffer[0..length.*], display_text[0..take]);
                        @memcpy(buffer[0..take], display_text[0..take]);
                        length.* = take;
                    }
                    result.editing = true;
                },
                .submitted => {
                    length.* = @min(buffer.len, session.buffer.items.len);
                    @memcpy(buffer[0..length.*], session.buffer.items[0..length.*]);
                    display_text = buffer[0..length.*];
                    result.submitted = true;
                    self.state.cancel_text();
                },
                .cancelled => {
                    result.cancelled = true;
                    self.state.cancel_text();
                },
            }
        } else self.state.cancel_text();
    }
    try self.background(id, rect, enabled, interaction, if (self.style.text_field) |theme| theme.background else null);
    try self.label(rect, display_text, if (enabled) self.style.foreground else self.style.disabled_text);
    return result;
}
pub const GridDrawer = struct { context: *anyopaque, draw: *const fn (*anyopaque, *Context, usize, layout.LogicalRect, bool) anyerror!void };
/// Selection indexes application-owned items; callbacks supply all item visuals.
pub fn selectable_grid(self: *Context, id: WidgetId, rect: layout.LogicalRect, count: usize, columns: usize, selected: *usize, drawer: GridDrawer, enabled: bool) !bool {
    try validate_rect(rect);
    if (columns == 0 or rect.width() <= 0 or rect.height() <= 0) return error.InvalidValue;
    const interaction = try self.interact(id, rect, .grid, enabled and count > 0);
    if (count == 0) return false;
    selected.* = @min(selected.*, count - 1);
    const rows = std.math.divCeil(usize, count, columns) catch return error.InvalidValue;
    if (rows > 32767 or columns > 32767) return error.InvalidValue;
    const previous_selected = selected.*;
    if (enabled and interaction.focused) if (self.frame.direction) |direction| switch (direction) {
        .left => {
            if (selected.* % columns > 0) selected.* -= 1;
        },
        .right => {
            if (selected.* % columns + 1 < columns and selected.* + 1 < count) selected.* += 1;
        },
        .up => {
            if (selected.* >= columns) selected.* -= columns;
        },
        .down => {
            if (columns < count - selected.*) selected.* += columns;
        },
    };
    if (enabled and interaction.focused and previous_selected == selected.*) if (self.frame.direction) |direction| self.navigate(direction, true);
    const hit = self.hit_bounds(id, rect);
    if (enabled and interaction.hovered and (self.frame.pointer_pressed or self.frame.pointer_released or self.frame.pointer_moved)) {
        const pointer = self.frame.pointer.?;
        const col: usize = @intCast(@divTrunc((@as(i32, pointer.x) - hit.x0) * @as(i32, @intCast(columns)), hit.width()));
        const row: usize = @intCast(@divTrunc((@as(i32, pointer.y) - hit.y0) * @as(i32, @intCast(rows)), hit.height()));
        selected.* = @min(row * columns + col, count - 1);
    }
    for (0..count) |i| {
        const col: i32 = @intCast(i % columns);
        const row: i32 = @intCast(i / columns);
        const cell: layout.LogicalRect = .{ .x0 = @intCast(@as(i32, rect.x0) + @divTrunc(col * rect.width(), @as(i32, @intCast(columns)))), .x1 = @intCast(@as(i32, rect.x0) + @divTrunc((col + 1) * rect.width(), @as(i32, @intCast(columns)))), .y0 = @intCast(@as(i32, rect.y0) + @divTrunc(row * rect.height(), @as(i32, @intCast(rows)))), .y1 = @intCast(@as(i32, rect.y0) + @divTrunc((row + 1) * rect.height(), @as(i32, @intCast(rows)))) };
        try drawer.draw(drawer.context, self, i, cell, selected.* == i);
    }
    return interaction.activated;
}
fn navigate(self: *Context, direction: InputAdapter.Direction, force: bool) void {
    if (self.state.active_text != null) return;
    const previous = self.state.focusables[self.state.current ^ 1][0..self.state.focus_count[self.state.current ^ 1]];
    if (previous.len == 0) return;
    var current: ?Focusable = null;
    for (previous) |item| if (self.state.focused == item.id) {
        current = item;
        break;
    };
    const source = current orelse {
        self.state.focused = previous[0].id;
        return;
    };
    if (!force and (source.kind == .grid or (source.kind == .slider and (!self.options.slider_capture or self.state.captured == source.id) and (direction == .left or direction == .right)))) return;
    var best: ?Focusable = null;
    var best_score: i64 = std.math.maxInt(i64);
    for (previous) |candidate| {
        if (candidate.id == source.id) continue;
        const dx: i64 = @as(i64, candidate.bounds.x0) + candidate.bounds.x1 - source.bounds.x0 - source.bounds.x1;
        const dy: i64 = @as(i64, candidate.bounds.y0) + candidate.bounds.y1 - source.bounds.y0 - source.bounds.y1;
        const forward: i64 = switch (direction) {
            .left => -dx,
            .right => dx,
            .up => -dy,
            .down => dy,
        };
        if (forward <= 0) continue;
        const cross = if (direction == .up or direction == .down) dx else dy;
        const score = forward * forward + 4 * cross * cross;
        if (score < best_score) {
            best = candidate;
            best_score = score;
        }
    }
    if (best) |target| {
        self.state.focused = target.id;
        if (target.scroll_id) |scroll_id| for (self.state.scrolls[0..self.state.scroll_count]) |*scroll| if (scroll.id == scroll_id) {
            const adjustment: i32 = if (target.bounds.y0 < scroll.viewport.y0) @as(i32, target.bounds.y0) - scroll.viewport.y0 else if (target.bounds.y1 > scroll.viewport.y1) @as(i32, target.bounds.y1) - scroll.viewport.y1 else 0;
            scroll.offset = @intCast(std.math.clamp(@as(i32, scroll.offset) + adjustment, 0, @max(0, @as(i32, scroll.content_height) - scroll.viewport.height())));
            break;
        };
    }
}

test "button capture release and directional focus use stable widget ids" {
    var state = try State.init(std.testing.allocator, .{});
    defer state.deinit();

    var draw = try DrawList.init(std.testing.allocator, .{});
    defer draw.deinit();

    const bounds: layout.LogicalRect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    var ui = try begin(&state, &draw, .{ .bounds = bounds });
    _ = try ui.button(1, "One", .{}, true);
    _ = try ui.button(2, "Two", .{}, true);
    try ui.end();
    try std.testing.expectEqual(@as(?WidgetId, 1), state.focused);
    draw.clear();
    ui = try begin(&state, &draw, .{ .bounds = bounds, .input = .{ .direction = .down, .confirm = true } });
    try std.testing.expect(!try ui.button(1, "One", .{}, true));
    try std.testing.expect(try ui.button(2, "Two", .{}, true));
    try ui.end();
    draw.clear();
    ui = try begin(&state, &draw, .{ .bounds = bounds, .input = .{ .pointer = .{ .x = 4, .y = 4 }, .pointer_pressed = true, .pointer_down = true } });
    try std.testing.expect(!try ui.button(1, "One", .{}, true));
    try ui.end();
    try std.testing.expectEqual(@as(?WidgetId, 1), state.captured);
    draw.clear();
    ui = try begin(&state, &draw, .{ .bounds = bounds, .input = .{ .pointer = .{ .x = 90, .y = 90 }, .pointer_released = true } });
    try std.testing.expect(!try ui.button(1, "One", .{}, true));
    try ui.end();
    try std.testing.expectEqual(null, state.captured);
}
test "scrolling clamps and clips child geometry" {
    var state = try State.init(std.testing.allocator, .{});
    defer state.deinit();

    var draw = try DrawList.init(std.testing.allocator, .{});
    defer draw.deinit();

    const bounds: layout.LogicalRect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 40 };
    var ui = try begin(&state, &draw, .{ .bounds = bounds, .input = .{ .pointer = .{ .x = 10, .y = 10 }, .wheel = -100 } });
    try ui.scroll_list(9, bounds, 100, 10);
    _ = try ui.button(1, "Clipped", .{}, true);
    try ui.end_stack();
    try ui.end();
    try std.testing.expectEqual(60, state.scroll_offset(9));
    try std.testing.expectEqual(bounds, draw.commands[0].clip.?);
    try std.testing.expectEqual(-60, draw.commands[0].value.rect.bounds.y0);
}

test "text widgets submit through existing bounded sessions and cancel on removal" {
    var system: input_api.InputSystem = .{};
    try system.init(std.testing.allocator);
    defer system.deinit();

    var state = try State.init(std.testing.allocator, .{});
    defer state.deinit();

    var draw = try DrawList.init(std.testing.allocator, .{});
    defer draw.deinit();

    const bounds: layout.LogicalRect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 20 };
    var buffer: [4]u8 = .{ 'o', 'l', 'd', 0 };
    var length: usize = 3;
    state.focused = 7;
    var ui = try begin(&state, &draw, .{ .bounds = bounds, .input = .{ .confirm = true, .input_system = &system } });
    try std.testing.expect((try ui.text_field(7, bounds, &buffer, &length, true)).editing);
    try ui.end();
    system.write_text_session_buffer("new!extra", .submitted);
    draw.clear();
    ui = try begin(&state, &draw, .{ .bounds = bounds, .input = .{ .input_system = &system } });
    try std.testing.expect((try ui.text_field(7, bounds, &buffer, &length, true)).submitted);
    try ui.end();
    try std.testing.expectEqualStrings("new!", buffer[0..length]);
    draw.clear();
    ui = try begin(&state, &draw, .{ .bounds = bounds, .input = .{ .confirm = true, .input_system = &system } });
    _ = try ui.text_field(7, bounds, &buffer, &length, true);
    try ui.end();
    draw.clear();
    ui = try begin(&state, &draw, .{ .bounds = bounds });
    try ui.end();
    try std.testing.expectEqual(input_api.TextInputStatus.cancelled, system.current_text_session().?.status);
    try std.testing.expectEqualStrings("new!", buffer[0..length]);
}

test "slider grid and intrinsic stack layout" {
    const Drawer = struct {
        fn draw(_: *anyopaque, ui: *Context, index: usize, rect: layout.LogicalRect, selected: bool) !void {
            _ = index;
            try ui.draw.add_rect(rect, if (selected) ui.style.focused else ui.style.background, 0);
        }
    };
    var state = try State.init(std.testing.allocator, .{});
    defer state.deinit();

    var draw = try DrawList.init(std.testing.allocator, .{});
    defer draw.deinit();

    const bounds: layout.LogicalRect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 100 };
    state.focused = 1;
    var ui = try begin(&state, &draw, .{ .bounds = bounds, .input = .{ .direction = .right } });
    try ui.stack(bounds, .{ .axis = .horizontal, .padding = .all(2), .gap = 4 });
    const rect = try ui.next(.{ .width = .{ .fixed = 40 }, .height = .content }, .{ .x = 0, .y = 20 });
    try std.testing.expectEqual(layout.LogicalRect{ .x0 = 2, .y0 = 2, .x1 = 42, .y1 = 22 }, rect);
    var value: f32 = 0.5;
    try std.testing.expect(try ui.slider(1, rect, &value, 0, 1, 0.25, true));
    try std.testing.expectEqual(@as(f32, 0.75), value);
    var selected: usize = 0;
    var token: u8 = 0;
    _ = try ui.selectable_grid(2, bounds, 3, 2, &selected, .{ .context = &token, .draw = Drawer.draw }, true);
    try ui.end_stack();
    try ui.end();
}

test "draw replay preserves controller slider capture until cancel" {
    var state = try State.init(std.testing.allocator, .{});
    defer state.deinit();

    var draw = try DrawList.init(std.testing.allocator, .{});
    defer draw.deinit();

    const bounds: layout.LogicalRect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 20 };
    state.focused = 1;
    var value: f32 = 0.5;
    var context = try begin(&state, &draw, .{ .bounds = bounds, .slider_capture = true, .paint = false, .input = .{ .confirm = true } });
    _ = try context.slider(1, bounds, &value, 0, 1, 0.1, true);
    try context.end();
    try std.testing.expectEqual(@as(?WidgetId, 1), state.captured);
    context = try begin(&state, &draw, .{ .bounds = bounds, .slider_capture = true, .paint = false, .replay = true });
    _ = try context.slider(1, bounds, &value, 0, 1, 0.1, true);
    try context.end();
    try std.testing.expectEqual(@as(?WidgetId, 1), state.captured);
    context = try begin(&state, &draw, .{ .bounds = bounds, .slider_capture = true, .paint = false, .input = .{ .cancel = true } });
    _ = try context.slider(1, bounds, &value, 0, 1, 0.1, true);
    try std.testing.expect(context.cancel_consumed);
    try context.end();
    try std.testing.expectEqual(null, state.captured);
}

test "text widgets handle live edits backspace and submit without replaying events" {
    var system: input_api.InputSystem = .{};
    try system.init(std.testing.allocator);
    defer system.deinit();

    const actions = try system.register_action_set("text-ui");
    try system.install_action_set(actions);
    try system.push_context(&.{ .name = "text-ui", .actions = actions, .cursor_mode = .visible, .consumes_text = true });

    var state = try State.init(std.testing.allocator, .{});
    defer state.deinit();

    var draw = try DrawList.init(std.testing.allocator, .{});
    defer draw.deinit();

    const bounds: layout.LogicalRect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 20 };
    var text: [16]u8 = undefined;
    var length: usize = 0;
    state.focused = 1;
    var context = try begin(&state, &draw, .{ .bounds = bounds, .paint = false, .live_text = true, .text_events = true, .input = .{ .input_system = &system, .confirm = true } });
    _ = try context.text_field(1, bounds, &text, &length, true);
    try context.end();
    system.deliver_text("abc");
    system.deliver_key_down(.Backspace, .{}, false);
    system.signal_frame_boundary();
    context = try begin(&state, &draw, .{ .bounds = bounds, .paint = false, .live_text = true, .text_events = true, .input = .{ .input_system = &system } });
    try std.testing.expect((try context.text_field(1, bounds, &text, &length, true)).changed);
    try context.end();
    try std.testing.expectEqualStrings("ab", text[0..length]);
    context = try begin(&state, &draw, .{ .bounds = bounds, .paint = false, .live_text = true, .text_events = true, .replay = true });
    _ = try context.text_field(1, bounds, &text, &length, true);
    try context.end();
    try std.testing.expectEqualStrings("ab", system.current_text_session().?.buffer.items);
    system.deliver_key_down(.Enter, .{}, false);
    system.signal_frame_boundary();
    context = try begin(&state, &draw, .{ .bounds = bounds, .paint = false, .live_text = true, .text_events = true, .input = .{ .input_system = &system, .confirm = true } });
    try std.testing.expect((try context.text_field(1, bounds, &text, &length, true)).submitted);
    try context.end();
    try std.testing.expectEqual(null, state.active_text);
}
