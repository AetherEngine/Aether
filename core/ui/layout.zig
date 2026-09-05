const std = @import("std");

pub const Anchor = enum(u8) {
    top_left,
    top_center,
    top_right,
    middle_left,
    middle_center,
    middle_right,
    bottom_left,
    bottom_center,
    bottom_right,
};

pub const Point = struct { x: i16, y: i16 };

pub const LogicalRect = struct {
    x0: i16,
    y0: i16,
    x1: i16,
    y1: i16,

    pub fn width(self: LogicalRect) i16 {
        return self.x1 - self.x0;
    }
    pub fn height(self: LogicalRect) i16 {
        return self.y1 - self.y0;
    }
    pub fn contains(self: LogicalRect, x: i16, y: i16) bool {
        return x >= self.x0 and x < self.x1 and y >= self.y0 and y < self.y1;
    }
};

/// Empty intersections have zero extent; rectangles must have ordered edges.
pub fn intersection(a: LogicalRect, optional_b: ?LogicalRect) LogicalRect {
    const b = optional_b orelse return a;
    const x0 = @max(a.x0, b.x0);
    const y0 = @max(a.y0, b.y0);
    return .{ .x0 = x0, .y0 = y0, .x1 = @max(x0, @min(a.x1, b.x1)), .y1 = @max(y0, @min(a.y1, b.y1)) };
}

pub fn contains_rect(outer: LogicalRect, inner: LogicalRect) bool {
    return inner.x0 >= outer.x0 and inner.y0 >= outer.y0 and inner.x1 <= outer.x1 and inner.y1 <= outer.y1;
}

pub fn anchor_point(anchor: Anchor, ex: i16, ey: i16) Point {
    return switch (anchor) {
        .top_left => .{ .x = 0, .y = 0 },
        .top_center => .{ .x = @divTrunc(ex, 2), .y = 0 },
        .top_right => .{ .x = ex, .y = 0 },
        .middle_left => .{ .x = 0, .y = @divTrunc(ey, 2) },
        .middle_center => .{ .x = @divTrunc(ex, 2), .y = @divTrunc(ey, 2) },
        .middle_right => .{ .x = ex, .y = @divTrunc(ey, 2) },
        .bottom_left => .{ .x = 0, .y = ey },
        .bottom_center => .{ .x = @divTrunc(ex, 2), .y = ey },
        .bottom_right => .{ .x = ex, .y = ey },
    };
}

/// Return the top-left origin for a child of `child_size` placed inside
/// `parent` with matching parent/child anchor points.
pub fn place_in_parent(parent: LogicalRect, child_size: Point, anchor: Anchor) Point {
    const ref = anchor_point(anchor, parent.width(), parent.height());
    const orig = anchor_point(anchor, child_size.x, child_size.y);
    return .{
        .x = parent.x0 + ref.x - orig.x,
        .y = parent.y0 + ref.y - orig.y,
    };
}

/// Includes the final partial logical pixel for screen-edge anchoring.
pub fn logical_width(screen_w: u32, scale: u32) u32 {
    return (screen_w + scale - 1) / scale;
}

pub fn logical_height(screen_h: u32, scale: u32) u32 {
    return (screen_h + scale - 1) / scale;
}

/// Converts logical pixels to SNORM NDC, with a top-left origin.
pub fn logical_to_snorm_x(x: i16, screen_w: u32, scale: u32) i16 {
    const s: i32 = @intCast(scale);
    const sw: i32 = @intCast(screen_w);
    const v = @divTrunc((2 * @as(i32, x) * s - sw) * 32767, sw);
    return @intCast(std.math.clamp(v, -32767, 32767));
}

pub fn logical_to_snorm_y(y: i16, screen_h: u32, scale: u32) i16 {
    const s: i32 = @intCast(scale);
    const sh: i32 = @intCast(screen_h);
    const v = @divTrunc((sh - 2 * @as(i32, y) * s) * 32767, sh);
    return @intCast(std.math.clamp(v, -32767, 32767));
}
