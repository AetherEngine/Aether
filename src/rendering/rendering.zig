pub const mesh = @import("mesh.zig");
pub const Mesh = mesh.Mesh;
pub const MeshData = mesh.MeshData;
pub const vertex = @import("Vertex.zig");
pub const Vertex = vertex.Vertex;
pub const Transform = @import("transform.zig");
pub const Camera = @import("camera.zig");
pub const Texture = @import("texture.zig");
const render_state = @import("render_state.zig");
pub const RenderState = render_state.RenderState;
pub const BlendMode = render_state.BlendMode;
pub const FogState = render_state.FogState;

pub const gfx = @import("../platform/platform.zig").gfx;

pub fn set_state(state: *const RenderState) void {
    gfx.api.set_render_state(state);
}

pub fn draw(comptime V: type, m: *Mesh(V), model: *const @import("../math/math.zig").Mat4) void {
    m.draw(model);
}

pub fn surface_size() struct { width: u32, height: u32 } {
    return .{
        .width = gfx.surface.get_width(),
        .height = gfx.surface.get_height(),
    };
}

pub fn aspect_ratio() f32 {
    const size = surface_size();
    return @as(f32, @floatFromInt(size.width)) / @as(f32, @floatFromInt(size.height));
}
