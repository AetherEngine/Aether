// Frustum extracted from a view-projection matrix (row-major, row-vector convention).
// Plane equation: normal.dot(p) + d >= 0 means the point is inside.

const std = @import("std");
const Vec3 = @import("vec3.zig");
const Mat4 = @import("mat4.zig");
const AABB = @import("aabb.zig");

pub const Plane = struct {
    normal: Vec3,
    d: f32,

    pub fn normalize(p: Plane) Plane {
        const len = p.normal.length();
        return .{ .normal = p.normal.scale(1.0 / len), .d = p.d / len };
    }

    pub fn distanceTo(p: Plane, v: Vec3) f32 {
        return Vec3.dot(p.normal, v) + p.d;
    }
};

/// Planes in order: left, right, bottom, top, near, far.
planes: [6]Plane,

const Self = @This();

/// Extract the six frustum planes from a combined view-projection matrix.
/// Uses the Gribb/Hartmann method adapted for row-major, row-vector matrices.
/// Assumes z in [0, 1] NDC.
pub fn fromViewProjection(vp: Mat4) Self {
    const m = vp.data;
    var self: Self = undefined;

    // Each plane: A = m[0][col_combo], B = m[1][col_combo], C = m[2][col_combo], D = m[3][col_combo]
    // Left:   col0 + col3
    self.planes[0] = Plane.normalize(.{
        .normal = Vec3.new(m[0][0] + m[0][3], m[1][0] + m[1][3], m[2][0] + m[2][3]),
        .d = m[3][0] + m[3][3],
    });
    // Right:  -col0 + col3
    self.planes[1] = Plane.normalize(.{
        .normal = Vec3.new(-m[0][0] + m[0][3], -m[1][0] + m[1][3], -m[2][0] + m[2][3]),
        .d = -m[3][0] + m[3][3],
    });
    // Bottom: col1 + col3
    self.planes[2] = Plane.normalize(.{
        .normal = Vec3.new(m[0][1] + m[0][3], m[1][1] + m[1][3], m[2][1] + m[2][3]),
        .d = m[3][1] + m[3][3],
    });
    // Top:   -col1 + col3
    self.planes[3] = Plane.normalize(.{
        .normal = Vec3.new(-m[0][1] + m[0][3], -m[1][1] + m[1][3], -m[2][1] + m[2][3]),
        .d = -m[3][1] + m[3][3],
    });
    // Near:   col2  (z in [0,1])
    self.planes[4] = Plane.normalize(.{
        .normal = Vec3.new(m[0][2], m[1][2], m[2][2]),
        .d = m[3][2],
    });
    // Far:   -col2 + col3
    self.planes[5] = Plane.normalize(.{
        .normal = Vec3.new(-m[0][2] + m[0][3], -m[1][2] + m[1][3], -m[2][2] + m[2][3]),
        .d = -m[3][2] + m[3][3],
    });

    return self;
}

pub fn containsPoint(self: Self, p: Vec3) bool {
    for (&self.planes) |*plane| {
        if (plane.distanceTo(p) < 0) return false;
    }
    return true;
}

/// Conservative AABB test — returns false only if the AABB is fully outside any plane.
pub fn containsAABB(self: Self, aabb: AABB) bool {
    for (&self.planes) |*plane| {
        // Positive vertex: the corner furthest in the plane's normal direction.
        const px = if (plane.normal.x >= 0) aabb.max.x else aabb.min.x;
        const py = if (plane.normal.y >= 0) aabb.max.y else aabb.min.y;
        const pz = if (plane.normal.z >= 0) aabb.max.z else aabb.min.z;
        if (plane.distanceTo(Vec3.new(px, py, pz)) < 0) return false;
    }
    return true;
}
