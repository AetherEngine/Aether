const std = @import("std");

pub const Vec3 = @import("vec3.zig");
pub const Mat4 = @import("mat4.zig");
pub const Quat = @import("quat.zig");
pub const Aabb = @import("aabb.zig");
pub const Frustum = @import("frustum.zig");
pub const GridRay = @import("grid_ray.zig");

const scalar = @import("scalar.zig");
pub const min = scalar.min;
pub const max = scalar.max;
pub const clamp = scalar.clamp;
pub const floor = scalar.floor;
pub const ceil = scalar.ceil;
pub const trunc = scalar.trunc;
pub const round = scalar.round;
pub const sin = scalar.sin;
pub const cos = scalar.cos;
pub const tan = scalar.tan;

test {
    std.testing.refAllDecls(Aabb);
    std.testing.refAllDecls(GridRay);
    std.testing.refAllDecls(scalar);
}
