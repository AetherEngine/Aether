const std = @import("std");
const Mat4 = @import("../math/math.zig").Mat4;
const Rendering = @import("../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;

/// The contract every graphics backend must satisfy. Each field names a
/// public top-level fn on the backend module and gives its exact type.
/// This struct is never instantiated — it exists purely to drive
/// `assertImpl` at comptime, replacing the runtime vtable that used to
/// hold function pointers here.
pub const Interface = struct {
    setup: fn (std.mem.Allocator, std.Io) void,
    init: fn () anyerror!void,
    deinit: fn () void,

    set_clear_color: fn (f32, f32, f32, f32) void,
    set_alpha_blend: fn (bool) void,
    set_fog: fn (bool, f32, f32, f32, f32, f32) void,
    set_clip_planes: fn (bool) void,
    set_proj_matrix: fn (*const Mat4) void,
    set_view_matrix: fn (*const Mat4) void,

    start_frame: fn () bool,
    end_frame: fn () void,
    clear_depth: fn () void,

    create_pipeline: fn (Pipeline.VertexLayout, ?[:0]align(4) const u8, ?[:0]align(4) const u8) anyerror!Pipeline.Handle,
    destroy_pipeline: fn (Pipeline.Handle) void,
    bind_pipeline: fn (Pipeline.Handle) void,

    create_mesh: fn (Pipeline.Handle) anyerror!Mesh.Handle,
    destroy_mesh: fn (Mesh.Handle) void,
    update_mesh: fn (Mesh.Handle, []const u8) void,
    draw_mesh: fn (Mesh.Handle, *const Mat4, usize, Mesh.Primitive) void,

    create_texture: fn (u32, u32, []align(16) u8) anyerror!Texture.Handle,
    update_texture: fn (Texture.Handle, []align(16) u8) void,
    bind_texture: fn (Texture.Handle) void,
    destroy_texture: fn (Texture.Handle) void,
    force_texture_resident: fn (Texture.Handle) void,
};

/// Verify at comptime that `Backend` exposes every decl in `Interface`
/// with the exact expected signature. Fires a clean compile error at the
/// call site if a backend's method set drifts.
pub fn assertImpl(comptime Backend: type) void {
    inline for (std.meta.fields(Interface)) |f| {
        if (!@hasDecl(Backend, f.name)) {
            @compileError("gfx backend " ++ @typeName(Backend) ++ " is missing decl: " ++ f.name);
        }
        const Actual = @TypeOf(@field(Backend, f.name));
        if (Actual != f.type) {
            @compileError("gfx backend " ++ @typeName(Backend) ++ "." ++ f.name ++
                " has type " ++ @typeName(Actual) ++ ", expected " ++ @typeName(f.type));
        }
    }
}
