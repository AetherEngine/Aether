const std = @import("std");
const math = @import("platform").math;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const Rendering = @import("rendering.zig");

fov: f32,
yaw: f32,
pitch: f32,
target: *const Vec3,

const Camera = @This();

pub fn update(self: *Camera) void {
    _ = self;
}

pub fn get_projection_matrix(self: *const Camera) Mat4 {
    return Mat4.perspective_fov_rh(std.math.degreesToRadians(self.fov), Rendering.aspect_ratio(), 0.3, 250.0);
}

pub fn get_view_matrix(self: *const Camera) Mat4 {
    const yaw = std.math.degreesToRadians(self.yaw);
    const pitch = std.math.degreesToRadians(self.pitch);

    const t = Mat4.translation(-self.target.x, -self.target.y, -self.target.z);
    const ry = Mat4.rotation_y(yaw);
    const rx = Mat4.rotation_x(pitch);

    return Mat4.mul(Mat4.mul(t, ry), rx);
}
