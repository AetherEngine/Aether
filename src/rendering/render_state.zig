const Mat4 = @import("../math/math.zig").Mat4;
const Texture = @import("texture.zig");

pub const BlendMode = enum {
    solid,
    alpha,
};

pub const FogState = struct {
    enabled: bool = false,
    start: f32 = 0.0,
    end: f32 = 0.0,
    color: [3]f32 = .{ 0.0, 0.0, 0.0 },
};

pub const RenderState = struct {
    texture: Texture.Handle = .none,
    proj: Mat4 = Mat4.identity(),
    view: Mat4 = Mat4.identity(),
    blend: BlendMode = .alpha,
    depth_write: bool = true,
    cull: bool = true,
    clip_planes: bool = false,
    fog: FogState = .{},
    uv_offset: [2]f32 = .{ 0.0, 0.0 },
};
