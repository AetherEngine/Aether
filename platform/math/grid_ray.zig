//! Unit-grid ray traversal without world storage or gameplay rules.
//! This is a thin ray, not a supercover: simultaneous boundary crossings enter
//! the diagonal cell once and omit cells touched only at an edge or corner.
const std = @import("std");
const Vec3 = @import("vec3.zig");
const GridRay = @This();

pub const Error = error{ InvalidQuery, CoordinateOverflow };
pub const Cell = struct {
    coordinate: [3]i32,
    /// Parameter in origin + direction * t; direction need not be normalized.
    enter: f64,
    /// Outward entry-face signs; multiple components are set for a tied
    /// crossing, so this is not necessarily a unit normal. Initially zero.
    normal: [3]i8,
};

coordinate: [3]i32,
step: [3]i8,
next_boundary: [3]f64,
delta: [3]f64,
max_t: f64,
first: bool = true,
done: bool = false,

/// Coordinates are bounded to signed 32-bit cells; init or next reports
/// CoordinateOverflow rather than wrapping. Directions may be zero. At an
/// exact boundary, negative travel starts in the cell on the negative side.
pub fn init(origin: Vec3, direction: Vec3, max_t: f32) Error!GridRay {
    if (!std.math.isFinite(max_t) or max_t < 0) return error.InvalidQuery;
    const origins = [3]f32{ origin.x, origin.y, origin.z };
    const directions = [3]f32{ direction.x, direction.y, direction.z };
    var self: GridRay = .{ .coordinate = undefined, .step = undefined, .next_boundary = undefined, .delta = undefined, .max_t = max_t };
    for (0..3) |axis| {
        const o: f64 = origins[axis];
        const d: f64 = directions[axis];
        if (!std.math.isFinite(o) or !std.math.isFinite(d)) return error.InvalidQuery;
        const floor = @floor(o);
        const cell = floor - @as(f64, if (d < 0 and o == floor) 1 else 0);
        if (cell < std.math.minInt(i32) or cell > std.math.maxInt(i32)) return error.CoordinateOverflow;
        self.coordinate[axis] = @intFromFloat(cell);
        self.step[axis] = if (d > 0) 1 else if (d < 0) -1 else 0;
        if (d == 0) {
            self.next_boundary[axis] = std.math.inf(f64);
            self.delta[axis] = std.math.inf(f64);
        } else {
            const edge = if (d > 0) cell + 1 else cell;
            self.next_boundary[axis] = (edge - o) / d;
            self.delta[axis] = 1 / @abs(d);
        }
    }
    return self;
}

pub fn next(self: *GridRay) Error!?Cell {
    if (self.done) return null;
    if (self.first) {
        self.first = false;
        return .{ .coordinate = self.coordinate, .enter = 0, .normal = .{ 0, 0, 0 } };
    }
    const enter = @min(self.next_boundary[0], self.next_boundary[1], self.next_boundary[2]);
    if (enter > self.max_t) {
        self.done = true;
        return null;
    }
    var coordinate = self.coordinate;
    var normal = [3]i8{ 0, 0, 0 };
    for (0..3) |axis| {
        if (self.next_boundary[axis] == enter) {
            coordinate[axis] = std.math.add(i32, coordinate[axis], self.step[axis]) catch {
                self.done = true;
                return error.CoordinateOverflow;
            };
            normal[axis] = -self.step[axis];
        }
    }
    for (0..3) |axis| if (self.next_boundary[axis] == enter) {
        self.next_boundary[axis] += self.delta[axis];
    };
    self.coordinate = coordinate;
    return .{ .coordinate = coordinate, .enter = enter, .normal = normal };
}

test "grid ray starts on the travel side and clips at the endpoint" {
    var ray = try init(Vec3.new(2, 0.5, 0.5), Vec3.new(-2, 0, 0), 1);
    const initial = (try ray.next()).?;
    try std.testing.expectEqual([3]i32{ 1, 0, 0 }, initial.coordinate);
    const second = (try ray.next()).?;
    try std.testing.expectEqual([3]i32{ 0, 0, 0 }, second.coordinate);
    try std.testing.expectEqual(@as(f64, 0.5), second.enter);
    try std.testing.expectEqual([3]i8{ 1, 0, 0 }, second.normal);
    try std.testing.expectEqual([3]i32{ -1, 0, 0 }, (try ray.next()).?.coordinate);
    try std.testing.expectEqual(@as(?Cell, null), try ray.next());
}

test "grid ray diagonal ties and stationary queries are deterministic" {
    var ray = try init(Vec3.new(0.5, 0.5, 0.5), Vec3.one(), 1);
    _ = try ray.next();
    const diagonal = (try ray.next()).?;
    try std.testing.expectEqual([3]i32{ 1, 1, 1 }, diagonal.coordinate);
    try std.testing.expectEqual([3]i8{ -1, -1, -1 }, diagonal.normal);
    try std.testing.expectEqual(@as(?Cell, null), try ray.next());
    ray = try init(Vec3.zero(), Vec3.zero(), 10);
    _ = try ray.next();
    try std.testing.expectEqual(@as(?Cell, null), try ray.next());
    try std.testing.expectError(error.InvalidQuery, init(Vec3.zero(), Vec3.one(), -1));
    try std.testing.expectError(error.CoordinateOverflow, init(Vec3.new(2147483648, 0, 0), Vec3.one(), 1));
}
