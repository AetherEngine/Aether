pub const mesh = @import("mesh.zig");
pub const MeshType = mesh.MeshType;
pub const MeshDataType = mesh.MeshDataType;
pub const vertex = @import("platform").graphics.vertex;
pub const Vertex = vertex.Vertex;
pub const Transform = @import("transform.zig");
pub const Camera = @import("camera.zig");
pub const Texture = @import("texture.zig");
const render_state = @import("platform").graphics;
pub const RenderState = render_state.RenderState;
pub const BlendMode = render_state.BlendMode;
pub const FogState = render_state.FogState;

pub const gfx = @import("platform").gfx;

/// Reject mesh uploads during drawing to catch unsafe borrowed-memory updates.
pub var validate_mesh_updates_outside_frame: bool = false;

/// Submits rendering state, using the engine's white texture for a null handle.
pub fn set_state(state: *const RenderState) void {
    var resolved = state.*;
    if (resolved.texture.is_null()) resolved.texture = Texture.Default.handle;
    gfx.api.set_render_state(&resolved);
}

pub fn draw(comptime V: type, m: *MeshType(V), model: *const @import("platform").math.Mat4) void {
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
