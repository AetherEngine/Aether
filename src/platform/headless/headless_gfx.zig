const std = @import("std");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;

pub const mesh_source_mode = Mesh.SourceMode.uploaded_copy;

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

pub fn init() anyerror!void {}
pub fn deinit() void {}

pub fn set_clear_color(_: f32, _: f32, _: f32, _: f32) void {}
pub fn set_alpha_blend(_: bool) void {}
pub fn set_depth_write(_: bool) void {}
pub fn set_fog(_: bool, _: f32, _: f32, _: f32, _: f32, _: f32) void {}
pub fn set_clip_planes(_: bool) void {}
pub fn set_culling(_: bool) void {}
pub fn set_uv_offset(_: f32, _: f32) void {}
pub fn set_proj_matrix(_: *const Mat4) void {}
pub fn set_view_matrix(_: *const Mat4) void {}
pub fn set_render_state(_: *const Rendering.RenderState) void {}

pub fn start_frame() bool {
    return false;
}

pub fn end_frame() void {}
pub fn clear_depth() void {}
pub fn has_second_screen() bool {
    return false;
}
pub fn switch_second_screen() void {
    unreachable;
}
pub fn set_vsync(_: bool) void {}

pub fn create_mesh(_: *const Mesh.Desc) anyerror!Mesh.Handle {
    return Mesh.Handle.none;
}

pub fn destroy_mesh(_: Mesh.Handle) void {}
pub fn update_mesh(_: Mesh.Handle, _: *const Mesh.UpdateDesc) void {}
pub fn draw_mesh(_: Mesh.Handle, _: *const Mat4) void {}

pub fn create_texture(_: *const Texture.UploadDesc) anyerror!Texture.Handle {
    return Texture.Handle.none;
}

pub fn update_texture(_: Texture.Handle, _: []align(16) u8) void {}
pub fn bind_texture(_: Texture.Handle) void {}
pub fn destroy_texture(_: Texture.Handle) void {}
pub fn force_texture_resident(_: Texture.Handle) void {}
