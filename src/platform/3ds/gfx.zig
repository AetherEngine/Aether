const std = @import("std");
const gfx = @import("../gfx.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;

pub fn setup(_: std.mem.Allocator, _: std.Io) void {}

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

pub fn start_frame() bool {
    return true;
}

pub fn end_frame() void {
    gfx.surface.draw();
}
pub fn clear_depth() void {}
pub fn set_vsync(v: bool) void {
    gfx.surface.sync = v;
}

pub fn create_mesh() anyerror!Mesh.Handle {
    return 0;
}

pub fn destroy_mesh(_: Mesh.Handle) void {}
pub fn update_mesh(_: Mesh.Handle, _: []const u8) void {}
pub fn draw_mesh(_: Mesh.Handle, _: *const Mat4, _: usize) void {}

pub fn create_texture(_: u32, _: u32, _: []align(16) u8) anyerror!Texture.Handle {
    return 0;
}

pub fn update_texture(_: Texture.Handle, _: []align(16) u8) void {}
pub fn bind_texture(_: Texture.Handle) void {}
pub fn destroy_texture(_: Texture.Handle) void {}
pub fn force_texture_resident(_: Texture.Handle) void {}
