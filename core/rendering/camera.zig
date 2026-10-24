const std = @import("std");
const math = @import("platform").math;
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Rendering = @import("rendering.zig");
const Camera = @This();

pub const AngleUnit = enum { degrees, radians };
pub const YawDirection = enum { right, left };
pub const PitchDirection = enum { down, up };
pub const Error = error{InvalidCamera};
pub const Matrices = struct {
    view: Mat4,
    projection: Mat4,
    view_projection: Mat4,
    frustum: math.Frustum,
};

fov: f32,
yaw: f32,
pitch: f32,
/// Borrowed camera position; the historical name is retained for compatibility.
target: *const Vec3,
near_plane: f32 = 0.3,
far_plane: f32 = 250.0,
/// Applies to fov, yaw and pitch. Defaults preserve existing camera matrices.
angle_unit: AngleUnit = .degrees,
/// At zero yaw/pitch the camera looks down -Z, with +Y up.
yaw_direction: YawDirection = .right,
pitch_direction: PitchDirection = .down,
/// Appended to the row-vector view matrix, before projection.
view_adjustment: ?Mat4 = null,
/// Most recently updated frustum; use matrices() for a fresh, pure query.
frustum: ?math.Frustum = null,

fn radians(self: *const Camera, angle: f32) f32 {
    return if (self.angle_unit == .degrees) std.math.degreesToRadians(angle) else angle;
}

/// Refreshes the cached frustum using the current rendering surface.
pub fn update(self: *Camera) void {
    self.update_for_aspect(Rendering.aspect_ratio()) catch {
        self.frustum = null;
    };
}

pub fn update_for_aspect(self: *Camera, aspect: f32) Error!void {
    const result = try self.matrices(aspect);
    self.frustum = result.frustum;
}

pub fn render_state(self: *const Camera, aspect: f32) Error!Rendering.RenderState {
    const result = try self.matrices(aspect);
    return .{ .proj = result.projection, .view = result.view };
}

/// Validated, surface-independent view, projection and matching culling planes.
pub fn matrices(self: *const Camera, aspect: f32) Error!Matrices {
    const fov = self.radians(self.fov);
    if (!std.math.isFinite(aspect) or aspect <= 0 or
        !std.math.isFinite(fov) or fov <= 0 or fov >= std.math.pi or
        !std.math.isFinite(self.near_plane) or self.near_plane <= 0 or
        !std.math.isFinite(self.far_plane) or self.far_plane <= self.near_plane or
        !std.math.isFinite(self.yaw) or !std.math.isFinite(self.pitch) or
        !std.math.isFinite(self.target.x) or !std.math.isFinite(self.target.y) or !std.math.isFinite(self.target.z))
        return error.InvalidCamera;
    const view = self.get_view_matrix();
    for (view.data) |row| for (row) |value| {
        if (!std.math.isFinite(value)) return error.InvalidCamera;
    };
    const projection = Mat4.perspective_fov_rh(fov, aspect, self.near_plane, self.far_plane);
    const view_projection = view.mul(projection);
    const frustum = math.Frustum.from_view_projection(view_projection);
    for (frustum.planes) |plane| {
        if (!std.math.isFinite(plane.normal.x) or !std.math.isFinite(plane.normal.y) or
            !std.math.isFinite(plane.normal.z) or !std.math.isFinite(plane.d)) return error.InvalidCamera;
    }
    return .{ .view = view, .projection = projection, .view_projection = view_projection, .frustum = frustum };
}

pub fn get_projection_matrix(self: *const Camera) Mat4 {
    return Mat4.perspective_fov_rh(self.radians(self.fov), Rendering.aspect_ratio(), self.near_plane, self.far_plane);
}

pub fn get_view_matrix(self: *const Camera) Mat4 {
    const yaw = self.radians(self.yaw) * @as(f32, if (self.yaw_direction == .right) 1 else -1);
    const pitch = self.radians(self.pitch) * @as(f32, if (self.pitch_direction == .down) 1 else -1);
    const view = Mat4.translation(-self.target.x, -self.target.y, -self.target.z)
        .mul(Mat4.rotation_y(yaw)).mul(Mat4.rotation_x(pitch));
    return if (self.view_adjustment) |adjustment| view.mul(adjustment) else view;
}
