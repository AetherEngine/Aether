const Vec3 = @import("vec3.zig");
const scalar = @import("scalar.zig");

x: f32,
y: f32,
z: f32,
w: f32,

const Quat = @This();

pub fn identity() Quat {
    return .{ .x = 0, .y = 0, .z = 0, .w = 1 };
}

pub fn from_axis_angle(axis: Vec3, angle: f32) Quat {
    const half = angle * 0.5;
    const s = scalar.sin(half);
    const n = axis.normalize();
    return .{ .x = n.x * s, .y = n.y * s, .z = n.z * s, .w = scalar.cos(half) };
}

/// Euler angles in radians: pitch (X), yaw (Y), roll (Z), applied in ZXY order.
pub fn from_euler(pitch: f32, yaw: f32, roll: f32) Quat {
    const hp = pitch * 0.5;
    const hy = yaw * 0.5;
    const hr = roll * 0.5;
    const sp = scalar.sin(hp);
    const cp = scalar.cos(hp);
    const sy = scalar.sin(hy);
    const cy = scalar.cos(hy);
    const sr = scalar.sin(hr);
    const cr = scalar.cos(hr);
    return .{
        .x = sp * cy * cr + cp * sy * sr,
        .y = cp * sy * cr - sp * cy * sr,
        .z = cp * cy * sr + sp * sy * cr,
        .w = cp * cy * cr - sp * sy * sr,
    };
}

pub fn mul(a: Quat, b: Quat) Quat {
    return .{
        .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
        .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
    };
}

pub fn normalize(q: Quat) Quat {
    const len = @sqrt(q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w);
    return .{ .x = q.x / len, .y = q.y / len, .z = q.z / len, .w = q.w / len };
}

pub fn conjugate(q: Quat) Quat {
    return .{ .x = -q.x, .y = -q.y, .z = -q.z, .w = q.w };
}

pub fn rotate_vec3(q: Quat, v: Vec3) Vec3 {
    const qv = Vec3.new(q.x, q.y, q.z);
    const t = Vec3.cross(qv, v).scale(2.0);
    return Vec3.add(Vec3.add(v, t.scale(q.w)), Vec3.cross(qv, t));
}
