//! Bounded deferred stack layout for a Context using deferred_hit_test.
//! Children are measured once, then geometry and hit rectangles move together.
const std = @import("std");
const assert = std.debug.assert;
const Context = @import("Context.zig");
const layout = @import("layout.zig");
const Flow = @This();
pub const Axis = Context.Axis;
pub const Size = Context.Size;
pub const CrossAlign = enum { start, center, end, stretch };
pub const Padding = struct {
    left: i16 = 0,
    right: i16 = 0,
    top: i16 = 0,
    bottom: i16 = 0,
    pub fn all(value: i16) Padding {
        return xy(value, value);
    }
    pub fn xy(x: i16, y: i16) Padding {
        return .{ .left = x, .right = x, .top = y, .bottom = y };
    }
    pub fn horizontal(self: Padding) i16 {
        return self.left + self.right;
    }
    pub fn vertical(self: Padding) i16 {
        return self.top + self.bottom;
    }
};
pub const Box = struct { width: Size = .content, height: Size = .content, min_w: i16 = 0, min_h: i16 = 0, max_w: i16 = 32767, max_h: i16 = 32767 };
pub const Options = struct { axis: Axis = .vertical, anchor: layout.Anchor = .middle_center, cross_align: CrossAlign = .center, gap: i16 = 0, padding: Padding = .{}, box: Box = .{}, wheel_step: i16 = 22 };
pub const Item = struct { first: Context.Mark, last: Context.Mark, rect: layout.LogicalRect, scope: usize };
pub const Scope = struct {
    options: Options,
    first: Context.Mark,
    item_start: usize,
    cursor: i16,
    cross: i16 = 0,
    children: usize = 0,
    reserved: ?layout.LogicalRect = null,
    scroll_id: ?Context.WidgetId = null,
    scroll_offset: i16 = 0,
    prior_scroll: ?Context.WidgetId = null,
};
screen: layout.LogicalRect,
scopes: []Scope,
items: []Item,
depth: usize = 0,
count: usize = 0,

pub fn init(screen: layout.LogicalRect, scopes: []Scope, items: []Item) Flow {
    return .{ .screen = screen, .scopes = scopes, .items = items };
}
pub fn stack(self: *Flow, context: *Context, options: Options) !void {
    if (self.depth == self.scopes.len) return error.StackCapacity;
    self.scopes[self.depth] = .{ .options = options, .first = context.mark(), .item_start = self.count, .cursor = if (options.axis == .vertical) options.padding.top else options.padding.left };
    self.depth += 1;
}
pub fn reserve(self: *Flow, size: layout.Point) layout.LogicalRect {
    assert(self.depth > 0);
    const scope = &self.scopes[self.depth - 1];
    if (scope.children > 0) scope.cursor += scope.options.gap;
    const rect: layout.LogicalRect = if (scope.options.axis == .vertical)
        .{ .x0 = scope.options.padding.left, .y0 = scope.cursor, .x1 = scope.options.padding.left + size.x, .y1 = scope.cursor + size.y }
    else
        .{ .x0 = scope.cursor, .y0 = scope.options.padding.top, .x1 = scope.cursor + size.x, .y1 = scope.options.padding.top + size.y };
    scope.cursor += if (scope.options.axis == .vertical) size.y else size.x;
    scope.cross = @max(scope.cross, if (scope.options.axis == .vertical) size.x else size.y);
    scope.children += 1;
    return rect;
}
pub fn record(self: *Flow, context: *Context, first: Context.Mark, rect: layout.LogicalRect) !void {
    if (self.count == self.items.len) return error.LayoutCapacity;
    self.items[self.count] = .{ .first = first, .last = context.mark(), .rect = rect, .scope = self.depth - 1 };
    self.count += 1;
}
pub fn scroll(self: *Flow, context: *Context, id: Context.WidgetId, size: layout.Point, options: Options) !void {
    const reserved = self.reserve(size);
    try self.stack(context, options);
    const scope = &self.scopes[self.depth - 1];
    scope.reserved = reserved;
    scope.scroll_id = id;
    scope.scroll_offset = context.state.scroll_offset(id);
    scope.prior_scroll = context.state.scopes[context.state.depth - 1].scroll_id;
    context.state.scopes[context.state.depth - 1].scroll_id = id;
}
pub fn end(self: *Flow, context: *Context) !void {
    if (self.depth == 0) return error.StackUnderflow;
    const scope = &self.scopes[self.depth - 1];
    const options = scope.options;
    const main = scope.cursor + (if (options.axis == .vertical) options.padding.bottom else options.padding.right);
    const cross = scope.cross + (if (options.axis == .vertical) options.padding.horizontal() else options.padding.vertical());
    var size: layout.Point = if (options.axis == .vertical) .{ .x = cross, .y = main } else .{ .x = main, .y = cross };
    size.x = resolve(options.box.width, size.x, self.screen.width(), options.box.min_w, options.box.max_w);
    size.y = resolve(options.box.height, size.y, self.screen.height(), options.box.min_h, options.box.max_h);
    if (scope.reserved) |viewport| size.x = viewport.width();
    const content_cross = if (options.axis == .vertical) size.x - options.padding.horizontal() else size.y - options.padding.vertical();
    for (self.items[scope.item_start..self.count]) |*item| {
        if (item.scope != self.depth - 1) continue;
        const child_cross = if (options.axis == .vertical) item.rect.width() else item.rect.height();
        const offset: i16 = switch (options.cross_align) {
            .start, .stretch => 0,
            .center => @divTrunc(content_cross - child_cross, 2),
            .end => content_cross - child_cross,
        };
        if (offset != 0) try context.translate(item.first, item.last, if (options.axis == .vertical) .{ .x = offset, .y = 0 } else .{ .x = 0, .y = offset });
    }
    if (scope.scroll_id) |id| {
        const viewport: layout.LogicalRect = .{ .x0 = 0, .y0 = scope.scroll_offset, .x1 = scope.reserved.?.width(), .y1 = scope.scroll_offset + scope.reserved.?.height() };
        try context.clip_range(scope.first, context.mark(), viewport);
        try context.register_scroll(id, viewport, size.y);
        for (context.state.scrolls[0..context.state.scroll_count]) |*entry| if (entry.id == id) {
            entry.geometry = .{ .first = scope.first, .last = context.mark() };
            entry.wheel_step = @max(0, options.wheel_step);
            break;
        };
        context.state.scopes[context.state.depth - 1].scroll_id = scope.prior_scroll;
    }
    const first = scope.first;
    const rect = scope.reserved orelse if (self.depth == 1) blk: {
        const origin = layout.place_in_parent(self.screen, size, options.anchor);
        break :blk layout.LogicalRect{ .x0 = origin.x, .y0 = origin.y, .x1 = origin.x + size.x, .y1 = origin.y + size.y };
    } else blk: {
        self.depth -= 1;
        const reserved = self.reserve(size);
        self.depth += 1;
        break :blk reserved;
    };
    const offset: layout.Point = .{ .x = rect.x0, .y = rect.y0 - scope.scroll_offset };
    try context.translate(first, context.mark(), offset);
    self.depth -= 1;
    if (self.depth > 0) try self.record(context, first, rect);
}
fn resolve(size: Size, content: i16, parent: i16, min: i16, max: i16) i16 {
    return std.math.clamp(switch (size) {
        .fixed => |fixed| fixed,
        .content => content,
        .fill => parent,
    }, min, max);
}
