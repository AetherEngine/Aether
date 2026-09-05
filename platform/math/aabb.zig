const Vec3 = @import("vec3.zig");

min: Vec3,
max: Vec3,

const Aabb = @This();

pub fn from_center_half_extents(c: Vec3, half: Vec3) Aabb {
    return .{
        .min = Vec3.sub(c, half),
        .max = Vec3.add(c, half),
    };
}

pub fn contains_point(self: Aabb, p: Vec3) bool {
    return p.x >= self.min.x and p.x <= self.max.x and
        p.y >= self.min.y and p.y <= self.max.y and
        p.z >= self.min.z and p.z <= self.max.z;
}

pub fn intersects(a: Aabb, b: Aabb) bool {
    return a.min.x <= b.max.x and a.max.x >= b.min.x and
        a.min.y <= b.max.y and a.max.y >= b.min.y and
        a.min.z <= b.max.z and a.max.z >= b.min.z;
}

pub fn expand(self: Aabb, p: Vec3) Aabb {
    return .{
        .min = Vec3.new(
            @min(self.min.x, p.x),
            @min(self.min.y, p.y),
            @min(self.min.z, p.z),
        ),
        .max = Vec3.new(
            @max(self.max.x, p.x),
            @max(self.max.y, p.y),
            @max(self.max.z, p.z),
        ),
    };
}

pub fn center(self: Aabb) Vec3 {
    return Vec3.scale(Vec3.add(self.min, self.max), 0.5);
}

pub fn half_extents(self: Aabb) Vec3 {
    return Vec3.scale(Vec3.sub(self.max, self.min), 0.5);
}

pub const QueryError = error{InvalidQuery};
pub const RayHit = struct {
    /// Parameters in origin + direction * t. Direction need not be normalized.
    enter: f32,
    exit: f32,
    /// Outward entry-face normal; zero when the query starts inside the box.
    normal: Vec3,
    started_inside: bool,
};
pub const SweepHit = struct {
    /// Fraction of the requested displacement, in [0, 1].
    time: f32,
    normal: Vec3,
    /// Strict initial overlap; a merely touching box is not an overlap.
    started_overlapping: bool,
};

/// Inclusive slab intersection, clipped to a finite, nonnegative t interval.
/// Parallel axes and zero-length directions are supported. Ties choose X, then
/// Y, then Z. Invalid bounds/non-finite inputs return InvalidQuery.
pub fn ray_intersection(self: Aabb, origin: Vec3, direction: Vec3, t_min: f32, t_max: f32) QueryError!?RayHit {
    const std = @import("std");
    if (!self.valid() or !finite_vector(origin) or !finite_vector(direction) or
        !std.math.isFinite(t_min) or !std.math.isFinite(t_max) or t_min < 0 or t_max < t_min) return error.InvalidQuery;
    const mins = [3]f32{ self.min.x, self.min.y, self.min.z };
    const maxs = [3]f32{ self.max.x, self.max.y, self.max.z };
    const origins = [3]f32{ origin.x, origin.y, origin.z };
    const directions = [3]f32{ direction.x, direction.y, direction.z };
    var enter: f64 = t_min;
    var exit: f64 = t_max;
    var normal = [3]f32{ 0, 0, 0 };
    var inside = true;
    for (0..3) |axis| {
        const o: f64 = origins[axis];
        const d: f64 = directions[axis];
        const lo: f64 = mins[axis];
        const hi: f64 = maxs[axis];
        const start = o + d * t_min;
        inside = inside and start >= lo and start <= hi;
        if (d == 0) {
            if (o < lo or o > hi) return null;
            continue;
        }
        const a = (lo - o) / d;
        const b = (hi - o) / d;
        const near = @min(a, b);
        const far = @max(a, b);
        if (near > enter) {
            enter = near;
            normal = .{ 0, 0, 0 };
            normal[axis] = if (d > 0) -1 else 1;
        }
        exit = @min(exit, far);
        if (enter > exit) return null;
    }
    return .{
        .enter = @floatCast(enter),
        .exit = @floatCast(exit),
        .normal = if (inside) Vec3.zero() else Vec3.new(normal[0], normal[1], normal[2]),
        .started_inside = inside,
    };
}

/// Sweeps this box by displacement against a stationary box. This pure query
/// does not move objects, slide, step, resolve penetration, or enumerate worlds.
/// Touching while moving away or parallel does not block movement.
pub fn sweep(self: Aabb, obstacle: Aabb, displacement: Vec3) QueryError!?SweepHit {
    if (!self.valid() or !obstacle.valid() or !finite_vector(displacement)) return error.InvalidQuery;
    const overlap = self.min.x < obstacle.max.x and self.max.x > obstacle.min.x and
        self.min.y < obstacle.max.y and self.max.y > obstacle.min.y and
        self.min.z < obstacle.max.z and self.max.z > obstacle.min.z;
    if (overlap) return .{ .time = 0, .normal = Vec3.zero(), .started_overlapping = true };
    const mins = [3]f32{ self.min.x, self.min.y, self.min.z };
    const maxs = [3]f32{ self.max.x, self.max.y, self.max.z };
    const other_mins = [3]f32{ obstacle.min.x, obstacle.min.y, obstacle.min.z };
    const other_maxs = [3]f32{ obstacle.max.x, obstacle.max.y, obstacle.max.z };
    const movement = [3]f32{ displacement.x, displacement.y, displacement.z };
    var contact_normal = Vec3.zero();
    for (0..3) |axis| {
        if ((maxs[axis] == other_mins[axis] and movement[axis] <= 0) or
            (mins[axis] == other_maxs[axis] and movement[axis] >= 0)) return null;
        if (maxs[axis] == other_mins[axis] or mins[axis] == other_maxs[axis]) {
            var normal = [3]f32{ 0, 0, 0 };
            normal[axis] = if (movement[axis] > 0) -1 else 1;
            if (contact_normal.length_sq() == 0) contact_normal = Vec3.new(normal[0], normal[1], normal[2]);
        }
    }
    const expanded: Aabb = .{ .min = obstacle.min.sub(self.max), .max = obstacle.max.sub(self.min) };
    const hit = (try expanded.ray_intersection(Vec3.zero(), displacement, 0, 1)) orelse return null;
    return .{ .time = hit.enter, .normal = if (hit.started_inside) contact_normal else hit.normal, .started_overlapping = false };
}

pub fn valid(self: Aabb) bool {
    return finite_vector(self.min) and finite_vector(self.max) and
        self.min.x <= self.max.x and self.min.y <= self.max.y and self.min.z <= self.max.z;
}

fn finite_vector(v: Vec3) bool {
    const std = @import("std");
    return std.math.isFinite(v.x) and std.math.isFinite(v.y) and std.math.isFinite(v.z);
}

test "ray AABB slabs cover parallel inside tangent and clipped intersections" {
    const t = @import("std").testing;
    const box: Aabb = .{ .min = Vec3.zero(), .max = Vec3.one() };
    const hit = (try box.ray_intersection(Vec3.new(-2, 0.5, 0.5), Vec3.new(2, 0, 0), 0, 10)).?;
    try t.expectEqual(@as(f32, 1), hit.enter);
    try t.expectEqual(@as(f32, 1.5), hit.exit);
    try t.expectEqual(Vec3.new(-1, 0, 0), hit.normal);
    try t.expect(!hit.started_inside);
    try t.expectEqual(@as(?RayHit, null), try box.ray_intersection(Vec3.new(-2, 2, 0.5), Vec3.new(1, 0, 0), 0, 10));
    try t.expectEqual(@as(?RayHit, null), try box.ray_intersection(Vec3.new(-2, 0, 0), Vec3.new(1, 0, 0), 0, 1));
    const inside = (try box.ray_intersection(Vec3.new(0.5, 0.5, 0.5), Vec3.zero(), 0, 1)).?;
    try t.expect(inside.started_inside);
    try t.expectEqual(Vec3.zero(), inside.normal);
    try t.expect((try box.ray_intersection(Vec3.new(-2, 1, 0), Vec3.new(1, 0, 0), 0, 10)) != null);
    try t.expectError(error.InvalidQuery, box.ray_intersection(Vec3.zero(), Vec3.one(), 2, 1));
}

test "sweeps report first impact initial overlap and nonblocking contact" {
    const t = @import("std").testing;
    const box: Aabb = .{ .min = Vec3.zero(), .max = Vec3.one() };
    const obstacle: Aabb = .{ .min = Vec3.new(3, 0, 0), .max = Vec3.new(4, 1, 1) };
    const hit = (try box.sweep(obstacle, Vec3.new(4, 0, 0))).?;
    try t.expectEqual(@as(f32, 0.5), hit.time);
    try t.expectEqual(Vec3.new(-1, 0, 0), hit.normal);
    try t.expect((try box.sweep(box, Vec3.zero())).?.started_overlapping);
    const touching: Aabb = .{ .min = Vec3.new(1, 0, 0), .max = Vec3.new(2, 1, 1) };
    try t.expectEqual(@as(?SweepHit, null), try box.sweep(touching, Vec3.new(-1, 0, 0)));
    try t.expectEqual(@as(?SweepHit, null), try box.sweep(touching, Vec3.new(0, 1, 0)));
    const contact = (try box.sweep(touching, Vec3.new(1, 0, 0))).?;
    try t.expectEqual(@as(f32, 0), contact.time);
    try t.expectEqual(Vec3.new(-1, 0, 0), contact.normal);
    try t.expect(!contact.started_overlapping);
}
