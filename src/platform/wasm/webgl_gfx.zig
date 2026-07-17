const std = @import("std");
const Mat4 = @import("../../math/math.zig").Mat4;
const Util = @import("../../util/util.zig");

const Rendering = @import("../../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const basic_vert align(@alignOf(u32)) = @embedFile("aether_basic_vert").*;
const basic_frag align(@alignOf(u32)) = @embedFile("aether_basic_frag").*;

const MAX_MESHES = 8192;
pub const mesh_source_mode = Mesh.SourceMode.uploaded_copy;

extern "aether_host" fn aether_webgl_init(vert_ptr: [*]const u8, vert_len: usize, frag_ptr: [*]const u8, frag_len: usize) bool;
extern "aether_host" fn aether_webgl_deinit() void;
extern "aether_host" fn aether_webgl_set_clear_color(r: f32, g: f32, b: f32, a: f32) void;
extern "aether_host" fn aether_webgl_set_alpha_blend(enabled: bool) void;
extern "aether_host" fn aether_webgl_set_depth_write(enabled: bool) void;
extern "aether_host" fn aether_webgl_set_culling(enabled: bool) void;
extern "aether_host" fn aether_webgl_set_uv_offset(u: f32, v: f32) void;
extern "aether_host" fn aether_webgl_set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void;
extern "aether_host" fn aether_webgl_set_proj_matrix(ptr: *const f32) void;
extern "aether_host" fn aether_webgl_set_view_matrix(ptr: *const f32) void;
extern "aether_host" fn aether_webgl_start_frame(width: u32, height: u32) bool;
extern "aether_host" fn aether_webgl_end_frame() void;
extern "aether_host" fn aether_webgl_clear_depth() void;
extern "aether_host" fn aether_webgl_create_mesh() u32;
extern "aether_host" fn aether_webgl_destroy_mesh(handle: u32) void;
extern "aether_host" fn aether_webgl_update_mesh(handle: u32, vertex_ptr: [*]const u8, vertex_len: usize, index_ptr: [*]const u8, index_len: usize) void;
extern "aether_host" fn aether_webgl_draw_mesh(handle: u32, model_ptr: *const f32) void;
extern "aether_host" fn aether_webgl_create_texture(width: u32, height: u32, ptr: [*]const u8, len: usize) u32;
extern "aether_host" fn aether_webgl_update_texture(handle: u32, ptr: [*]const u8, len: usize) void;
extern "aether_host" fn aether_webgl_bind_texture(handle: u32) void;
extern "aether_host" fn aether_webgl_destroy_texture(handle: u32) void;
extern "aether_host" fn aether_canvas_width() u32;
extern "aether_host" fn aether_canvas_height() u32;

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;
var meshes = Util.ResourceTable(u32, MAX_MESHES, Mesh.Handle).init();
var textures = Util.ResourceTable(u32, 4096, Texture.Handle).init();

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
    _ = render_alloc;
    _ = render_io;
}

pub fn init() anyerror!void {
    if (!aether_webgl_init(&basic_vert, basic_vert.len, &basic_frag, basic_frag.len)) {
        return error.WebGlInitFailed;
    }
}

pub fn deinit() void {
    aether_webgl_deinit();
}

pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    aether_webgl_set_clear_color(r, g, b, a);
}

pub fn set_alpha_blend(enabled: bool) void {
    aether_webgl_set_alpha_blend(enabled);
}

pub fn set_depth_write(enabled: bool) void {
    aether_webgl_set_depth_write(enabled);
}

pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    aether_webgl_set_fog(enabled, start, end, r, g, b);
}

pub fn set_clip_planes(_: bool) void {}

pub fn set_culling(enabled: bool) void {
    aether_webgl_set_culling(enabled);
}

pub fn set_uv_offset(u: f32, v: f32) void {
    aether_webgl_set_uv_offset(u, v);
}

pub fn set_proj_matrix(mat: *const Mat4) void {
    aether_webgl_set_proj_matrix(mat.ptr());
}

pub fn set_view_matrix(mat: *const Mat4) void {
    aether_webgl_set_view_matrix(mat.ptr());
}

pub fn set_render_state(state: *const Rendering.RenderState) void {
    set_alpha_blend(state.blend == .alpha);
    set_depth_write(state.depth_write);
    set_culling(state.cull);
    set_clip_planes(state.clip_planes);
    set_uv_offset(state.uv_offset[0], state.uv_offset[1]);
    set_fog(state.fog.enabled, state.fog.start, state.fog.end, state.fog.color[0], state.fog.color[1], state.fog.color[2]);
    set_proj_matrix(&state.proj);
    set_view_matrix(&state.view);
    bind_texture(if (state.texture.is_null()) Texture.Default.handle else state.texture);
}

pub fn start_frame() bool {
    const width = aether_canvas_width();
    const height = aether_canvas_height();
    if (width == 0 or height == 0) return false;
    return aether_webgl_start_frame(width, height);
}

pub fn end_frame() void {
    aether_webgl_end_frame();
}

pub fn clear_depth() void {
    aether_webgl_clear_depth();
}

pub fn has_second_screen() bool {
    return false;
}

pub fn switch_second_screen() void {
    unreachable;
}

pub fn set_vsync(_: bool) void {}

pub fn create_mesh(_: *const Mesh.Desc) anyerror!Mesh.Handle {
    const host_handle = aether_webgl_create_mesh();
    if (host_handle == 0) return error.OutOfMeshes;
    return meshes.add(host_handle) orelse return error.OutOfMeshes;
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    const host_handle = meshes.get(handle) orelse return;
    aether_webgl_destroy_mesh(host_handle);
    _ = meshes.remove(handle);
}

pub fn update_mesh(handle: Mesh.Handle, desc: *const Mesh.UpdateDesc) void {
    const host_handle = meshes.get(handle) orelse return;
    const data = desc.vertices;
    const indices = desc.indices;
    const index_bytes = std.mem.sliceAsBytes(indices);
    aether_webgl_update_mesh(host_handle, data.ptr, data.len, index_bytes.ptr, index_bytes.len);
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4) void {
    const host_handle = meshes.get(handle) orelse return;
    aether_webgl_draw_mesh(host_handle, model.ptr());
}

pub fn create_texture(desc: *const Texture.UploadDesc) anyerror!Texture.Handle {
    const width = desc.width;
    const height = desc.height;
    const data = desc.pixels;
    const handle = aether_webgl_create_texture(width, height, data.ptr, data.len);
    if (handle == 0) return error.TextureCreateFailed;
    return textures.add(handle) orelse {
        aether_webgl_destroy_texture(handle);
        return error.OutOfTextures;
    };
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const host_handle = textures.get(handle) orelse return;
    aether_webgl_update_texture(host_handle, data.ptr, data.len);
}

pub fn bind_texture(handle: Texture.Handle) void {
    const host_handle = textures.get(handle) orelse return;
    aether_webgl_bind_texture(host_handle);
}

pub fn destroy_texture(handle: Texture.Handle) void {
    const host_handle = textures.get(handle) orelse return;
    aether_webgl_destroy_texture(host_handle);
    _ = textures.remove(handle);
}

pub fn force_texture_resident(_: Texture.Handle) void {}
