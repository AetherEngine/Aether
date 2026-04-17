const std = @import("std");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;

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
pub fn set_proj_matrix(_: *const Mat4) void {}
pub fn set_view_matrix(_: *const Mat4) void {}

pub fn start_frame() bool {
    return false;
}

pub fn end_frame() void {}
pub fn clear_depth() void {}
pub fn set_vsync(_: bool) void {}

pub fn create_pipeline(_: Pipeline.VertexLayout, _: ?[:0]align(4) const u8, _: ?[:0]align(4) const u8) anyerror!Pipeline.Handle {
    return 0;
}

pub fn destroy_pipeline(_: Pipeline.Handle) void {}
pub fn bind_pipeline(_: Pipeline.Handle) void {}

pub fn create_mesh(_: Pipeline.Handle) anyerror!Mesh.Handle {
    return 0;
}

pub fn destroy_mesh(_: Mesh.Handle) void {}
pub fn update_mesh(_: Mesh.Handle, _: []const u8) void {}
pub fn draw_mesh(_: Mesh.Handle, _: *const Mat4, _: usize, _: Mesh.Primitive) void {}

pub fn create_texture(_: u32, _: u32, _: []align(16) u8) anyerror!Texture.Handle {
    return 0;
}

pub fn update_texture(_: Texture.Handle, _: []align(16) u8) void {}
pub fn bind_texture(_: Texture.Handle) void {}
pub fn destroy_texture(_: Texture.Handle) void {}
pub fn force_texture_resident(_: Texture.Handle) void {}
