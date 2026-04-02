const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const GFXAPI = @import("../gfx_api.zig");

const Self = @This();

fn init(_: *anyopaque) !void {}

fn deinit(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);
    Util.allocator(.render).destroy(self);
}

fn set_clear_color(_: *anyopaque, _: f32, _: f32, _: f32, _: f32) void {}
fn set_alpha_blend(_: *anyopaque, _: bool) void {}
fn set_proj_matrix(_: *anyopaque, _: *const Mat4) void {}
fn set_view_matrix(_: *anyopaque, _: *const Mat4) void {}

fn start_frame(_: *anyopaque) bool {
    return false;
}

fn end_frame(_: *anyopaque) void {}

fn create_pipeline(_: *anyopaque, _: Pipeline.VertexLayout, _: ?[:0]align(4) const u8, _: ?[:0]align(4) const u8) !Pipeline.Handle {
    return 0;
}

fn destroy_pipeline(_: *anyopaque, _: Pipeline.Handle) void {}
fn bind_pipeline(_: *anyopaque, _: Pipeline.Handle) void {}

fn create_mesh(_: *anyopaque, _: Pipeline.Handle) !Mesh.Handle {
    return 0;
}

fn destroy_mesh(_: *anyopaque, _: Mesh.Handle) void {}
fn update_mesh(_: *anyopaque, _: Mesh.Handle, _: []const u8) void {}
fn draw_mesh(_: *anyopaque, _: Mesh.Handle, _: *const Mat4, _: usize) void {}

fn create_texture(_: *anyopaque, _: u32, _: u32, _: []align(16) u8) !Texture.Handle {
    return 0;
}

fn update_texture(_: *anyopaque, _: Texture.Handle, _: []align(16) u8) void {}
fn bind_texture(_: *anyopaque, _: Texture.Handle) void {}
fn destroy_texture(_: *anyopaque, _: Texture.Handle) void {}
fn force_texture_resident(_: *anyopaque, _: Texture.Handle) void {}

pub fn gfx_api(self: *Self) GFXAPI {
    return GFXAPI{ .ptr = self, .tab = &.{
        .init = init,
        .deinit = deinit,
        .set_clear_color = set_clear_color,
        .set_alpha_blend = set_alpha_blend,
        .set_proj_matrix = set_proj_matrix,
        .set_view_matrix = set_view_matrix,
        .start_frame = start_frame,
        .end_frame = end_frame,
        .create_pipeline = create_pipeline,
        .destroy_pipeline = destroy_pipeline,
        .bind_pipeline = bind_pipeline,
        .create_mesh = create_mesh,
        .destroy_mesh = destroy_mesh,
        .update_mesh = update_mesh,
        .draw_mesh = draw_mesh,
        .create_texture = create_texture,
        .update_texture = update_texture,
        .bind_texture = bind_texture,
        .destroy_texture = destroy_texture,
        .force_texture_resident = force_texture_resident,
    } };
}
