// Row-major 4x4 float matrix. data[row][col].
// Memory layout matches zmath's Mat ([4]@Vector(4,f32)), so pointers can be
// cast directly to *f32 for OpenGL/Vulkan UBO and push-constant uploads.

const std = @import("std");
const Vec3 = @import("vec3.zig");
const Quat = @import("quat.zig");

data: [4][4]f32,

const Self = @This();

pub fn identity() Self {
    return .{ .data = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };
}

pub fn mul(a: Self, b: Self) Self {
    var result: Self = undefined;
    inline for (0..4) |i| {
        inline for (0..4) |j| {
            var sum: f32 = 0;
            inline for (0..4) |k| sum += a.data[i][k] * b.data[k][j];
            result.data[i][j] = sum;
        }
    }
    return result;
}

pub fn translation(x: f32, y: f32, z: f32) Self {
    return .{ .data = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ x, y, z, 1 },
    } };
}

pub fn scaling(x: f32, y: f32, z: f32) Self {
    return .{ .data = .{
        .{ x, 0, 0, 0 },
        .{ 0, y, 0, 0 },
        .{ 0, 0, z, 0 },
        .{ 0, 0, 0, 1 },
    } };
}

pub fn rotationX(angle: f32) Self {
    const s = @sin(angle);
    const c = @cos(angle);
    return .{ .data = .{
        .{ 1, 0,  0, 0 },
        .{ 0, c,  s, 0 },
        .{ 0, -s, c, 0 },
        .{ 0, 0,  0, 1 },
    } };
}

pub fn rotationY(angle: f32) Self {
    const s = @sin(angle);
    const c = @cos(angle);
    return .{ .data = .{
        .{ c,  0, -s, 0 },
        .{ 0,  1,  0, 0 },
        .{ s,  0,  c, 0 },
        .{ 0,  0,  0, 1 },
    } };
}

pub fn rotationZ(angle: f32) Self {
    const s = @sin(angle);
    const c = @cos(angle);
    return .{ .data = .{
        .{  c, s, 0, 0 },
        .{ -s, c, 0, 0 },
        .{  0, 0, 1, 0 },
        .{  0, 0, 0, 1 },
    } };
}

/// Right-handed perspective, OpenGL NDC (z in [-1, 1]).
/// fov is the full vertical field-of-view in radians.
pub fn perspectiveFovRhGl(fov: f32, aspect: f32, near: f32, far: f32) Self {
    const f = 1.0 / @tan(fov * 0.5);
    return .{ .data = .{
        .{ f / aspect, 0, 0,                              0  },
        .{ 0,          f, 0,                              0  },
        .{ 0,          0, (near + far) / (near - far),   -1  },
        .{ 0,          0, 2.0 * far * near / (near - far), 0  },
    } };
}

/// Right-handed orthographic, Vulkan NDC (z in [0, 1]).
/// width and height are the full extents of the view volume.
pub fn orthographicRh(width: f32, height: f32, near: f32, far: f32) Self {
    return .{ .data = .{
        .{ 2.0 / width, 0,            0,                   0 },
        .{ 0,           2.0 / height, 0,                   0 },
        .{ 0,           0,            1.0 / (near - far),  0 },
        .{ 0,           0,            near / (near - far), 1 },
    } };
}

/// Build a rotation matrix from a unit quaternion.
pub fn fromQuat(q: Quat) Self {
    const x = q.x;
    const y = q.y;
    const z = q.z;
    const w = q.w;
    return .{ .data = .{
        .{ 1 - 2*(y*y + z*z),  2*(x*y + w*z),      2*(x*z - w*y),      0 },
        .{ 2*(x*y - w*z),      1 - 2*(x*x + z*z),  2*(y*z + w*x),      0 },
        .{ 2*(x*z + w*y),      2*(y*z - w*x),      1 - 2*(x*x + y*y),  0 },
        .{ 0,                  0,                  0,                  1 },
    } };
}

/// Returns a pointer to the first element for GPU uploads.
pub fn ptr(self: *const Self) *const f32 {
    return &self.data[0][0];
}
