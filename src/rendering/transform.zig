const std = @import("std");
const math = @import("../math/math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

pos: Vec3,
rot: Vec3,
scale: Vec3,

const Transform = @This();

pub fn new() Transform {
    return .{
        .pos = Vec3.zero(),
        .rot = Vec3.zero(),
        .scale = Vec3.one(),
    };
}

pub fn get_matrix(self: *const Transform) Mat4 {
    const s = Mat4.scaling(self.scale.x, self.scale.y, self.scale.z);
    const rx = Mat4.rotation_x(std.math.degreesToRadians(self.rot.x));
    const ry = Mat4.rotation_y(std.math.degreesToRadians(self.rot.y));
    const rz = Mat4.rotation_z(std.math.degreesToRadians(self.rot.z));
    const t = Mat4.translation(self.pos.x, self.pos.y, self.pos.z);
    const rotation = Mat4.mul(Mat4.mul(rz, rx), ry);
    return Mat4.mul(s, Mat4.mul(rotation, t));
}
