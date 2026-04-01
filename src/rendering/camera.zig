const std = @import("std");
const math = @import("../math/math.zig");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;

const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

fov: f32,
yaw: f32,
pitch: f32,
target: *const Vec3,

const Self = @This();

/// A simple 3D camera with position and orientation.
pub fn update(self: *Self) void {
    gfx.api.set_proj_matrix(&self.get_projection_matrix());
    gfx.api.set_view_matrix(&self.get_view_matrix());
}

/// Computes and returns the camera's projection matrix based on its field of view and the current aspect ratio.
pub fn get_projection_matrix(self: *Self) Mat4 {
    const width: f32 = @floatFromInt(gfx.surface.get_width());
    const height: f32 = @floatFromInt(gfx.surface.get_height());
    return Mat4.perspectiveFovRh(std.math.degreesToRadians(self.fov), width / height, 0.3, 250.0);
}

/// Computes and returns the camera's view matrix based on its yaw and pitch angles, from the perspective of the target position.
pub fn get_view_matrix(self: *Self) Mat4 {
    const yaw = std.math.degreesToRadians(self.yaw);
    const pitch = std.math.degreesToRadians(self.pitch);

    // Negative because we want to move the world opposite to the camera
    const t = Mat4.translation(-self.target.x, -self.target.y, -self.target.z);

    // Negative because we want to rotate the world opposite to the camera
    const ry = Mat4.rotationY(yaw);
    const rx = Mat4.rotationX(pitch);

    return Mat4.mul(Mat4.mul(t, ry), rx);
}
