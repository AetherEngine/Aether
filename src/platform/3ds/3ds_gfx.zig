//! Citro3D graphics backend for Nintendo 3DS.

const std = @import("std");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const vertex = Rendering.vertex;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const shaders = @import("aether_shaders");

const c = @cImport({
    @cDefine("wint_t", "unsigned int");
    @cInclude("3ds/types.h");
    @cInclude("3ds/gpu/enums.h");
    @cInclude("3ds/gpu/gpu.h");
    @cInclude("3ds/gpu/gx.h");
    @cInclude("3ds/services/gspgpu.h");
    @cInclude("3ds/gfx.h");
    @cInclude("3ds/allocator/vram.h");
    @cInclude("3ds/gpu/shbin.h");
    @cInclude("3ds/gpu/shaderProgram.h");
    @cUndef("__3DS__");
    @cUndef("_3DS");
    @cInclude("c3d/types.h");
    @cInclude("c3d/maths.h");
    @cInclude("c3d/uniforms.h");
    @cInclude("c3d/attribs.h");
    @cInclude("c3d/buffers.h");
    @cInclude("c3d/base.h");
    @cInclude("c3d/texenv.h");
    @cInclude("c3d/effect.h");
    @cInclude("c3d/texture.h");
    @cInclude("c3d/fog.h");
    @cInclude("c3d/framebuffer.h");
    @cInclude("c3d/renderqueue.h");
});

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

const SCREEN_WIDTH: u32 = 400;
const SCREEN_HEIGHT: u32 = 240;
const TARGET_WIDTH: c_int = 240;
const TARGET_HEIGHT: c_int = 400;
const MAX_VERTEX_ATTRS: usize = 12;
const MESH_SLOT_COUNT: usize = 2;
const MAX_DEFERRED_MESH_FREES: usize = 4096;
const C3D_CMD_BUFFER_SIZE: usize = 1024 * 1024;
const MAX_TEXTURE_SIZE: u32 = 1024;
const MIN_TEXTURE_SIZE: u32 = 8;
const TEX_BPP: usize = 4;
const OS_FCRAM_VADDR: usize = 0x30000000;
const OS_FCRAM_SIZE: usize = 0x10000000;
const OS_OLD_FCRAM_VADDR: usize = 0x14000000;
const OS_OLD_FCRAM_SIZE: usize = 0x08000000;

const DISPLAY_TRANSFER_FLAGS: u32 = @intCast(
    c.GX_TRANSFER_FLIP_VERT(0) |
        c.GX_TRANSFER_OUT_TILED(0) |
        c.GX_TRANSFER_RAW_COPY(0) |
        c.GX_TRANSFER_IN_FORMAT(c.GX_TRANSFER_FMT_RGBA8) |
        c.GX_TRANSFER_OUT_FORMAT(c.GX_TRANSFER_FMT_RGB8) |
        c.GX_TRANSFER_SCALING(c.GX_TRANSFER_SCALE_NO),
);

const ShaderType = c.GPU_SHADER_TYPE;
const VERTEX_SHADER: ShaderType = @intCast(c.GPU_VERTEX_SHADER);
const VERTEX_SHADER_INDEX: usize = 0;

const BufferBinding = struct {
    offset: usize,
    vertex_span: usize,
    attrib_count: c_int,
    permutation: u64,
};

const PipelineData = struct {
    dvlb: [*c]c.DVLB_s,
    program: c.shaderProgram_s,
    attr_info: c.C3D_AttrInfo,
    stride: usize,
    buffer: BufferBinding,
    pos_scale: [4]f32,
    uv_scale: [2]f32,
    color_scale: [4]f32,
    u_projection: c_int,
    u_model_view: c_int,
    u_pos_scale: c_int,
    u_uv_scale_offset: c_int,
    u_color_scale: c_int,
};

const MeshData = struct {
    slots: [MESH_SLOT_COUNT]MeshSlot = .{ .{}, .{} },
    latest_slot: ?usize = null,
    len: usize,
};

const MeshSlot = struct {
    data: ?[]align(16) u8 = null,
    len: usize = 0,
    in_flight: bool = false,
    used_this_frame: bool = false,
};

const DeferredMeshFree = struct {
    data: []align(16) u8,
};

const TexMirror = extern struct {
    data: ?*anyopaque,
    fmt_size: u32,
    dim: u32,
    param: u32,
    border: u32,
    lod_param: u32,
};

comptime {
    std.debug.assert(@sizeOf(TexMirror) == 24);
}

const TextureData = struct {
    width: u32,
    height: u32,
    tex: TexMirror,
    staging: ?[]align(16) u8 = null,
};

const TexEnvMirror = extern struct {
    src_rgb: u16,
    src_alpha: u16,
    op_all: u32,
    func_rgb: u16,
    func_alpha: u16,
    color: u32,
    scale_rgb: u16,
    scale_alpha: u16,
};

comptime {
    std.debug.assert(@sizeOf(TexEnvMirror) == 20);
}

const FrameBufMirror = extern struct {
    color_buf: ?*anyopaque,
    depth_buf: ?*anyopaque,
    width: u16,
    height: u16,
    color_fmt: c.GPU_COLORBUF,
    depth_fmt: c.GPU_DEPTHBUF,
    block32: bool,
    masks: u8,
};

const RenderTargetMirror = extern struct {
    next: ?*c.C3D_RenderTarget,
    prev: ?*c.C3D_RenderTarget,
    frame_buf: FrameBufMirror,
};

var meshes = Util.CircularBuffer(MeshData, 2048).init();
var deferred_mesh_frees = Util.CircularBuffer(DeferredMeshFree, MAX_DEFERRED_MESH_FREES + 1).init();
var textures = Util.CircularBuffer(TextureData, 64).init();
var render_pipeline: PipelineData = undefined;
var render_pipeline_initialized = false;

var target: ?*c.C3D_RenderTarget = null;
var projection_transform: c.C3D_Mtx = undefined;
var fog_lut: c.C3D_FogLut = undefined;
var initialized = false;
var frame_started = false;
var vsync_enabled = true;
var clear_color: u32 = 0x000000ff;
var alpha_blend_enabled = true;
var depth_write_enabled = true;
var cull_face_enabled = true;
var fog_enabled = false;
var uv_offset: [2]f32 = .{ 0.0, 0.0 };
var proj_matrix: Mat4 = Mat4.identity();
var view_matrix: Mat4 = Mat4.identity();
var bound_texture: Texture.Handle = 0;

pub fn init() anyerror!void {
    _ = render_alloc;
    _ = render_io;

    c.gfxInitDefault();
    if (!c.C3D_Init(C3D_CMD_BUFFER_SIZE)) {
        c.gfxExit();
        return error.C3DInitFailed;
    }
    errdefer {
        c.C3D_Fini();
        c.gfxExit();
    }

    target = c.C3D_RenderTargetCreate(
        TARGET_WIDTH,
        TARGET_HEIGHT,
        c.GPU_RB_RGBA8,
        c.C3D_DEPTHTYPE{ .__e = c.GPU_RB_DEPTH24_STENCIL8 },
    ) orelse return error.C3DRenderTargetCreateFailed;
    errdefer {
        c.C3D_RenderTargetDelete(target);
        target = null;
    }

    c.C3D_RenderTargetSetOutput(target, c.GFX_TOP, c.GFX_LEFT, DISPLAY_TRANSFER_FLAGS);
    init_projection_transform();
    render_pipeline = try init_pipeline(vertex.Layout);
    render_pipeline_initialized = true;

    initialized = true;
    frame_started = false;
    apply_render_state();
    init_texenvs();
}

pub fn deinit() void {
    frame_started = false;
    if (initialized) c.C3D_FrameSync();
    release_completed_mesh_slots();
    free_deferred_mesh_slots();

    for (1..textures.buffer.len) |i| {
        if (textures.buffer[i]) |*tex| {
            c.C3D_TexDelete(tex_ptr(tex));
            free_texture_staging(tex);
        }
    }
    textures.clear();

    if (render_pipeline_initialized) {
        deinit_pipeline(&render_pipeline);
        render_pipeline_initialized = false;
    }

    for (1..meshes.buffer.len) |i| {
        if (meshes.buffer[i]) |*mesh| {
            free_mesh_slots(mesh);
        }
    }
    meshes.clear();

    if (target) |t| {
        c.C3D_RenderTargetDelete(t);
        target = null;
    }

    if (initialized) {
        c.C3D_Fini();
        c.gfxExit();
        initialized = false;
    }
}

pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    clear_color = pack_color_rgba(r, g, b, a);
}

pub fn set_alpha_blend(enabled: bool) void {
    alpha_blend_enabled = enabled;
    if (!initialized) return;

    if (enabled) {
        c.C3D_AlphaBlend(
            c.GPU_BLEND_ADD,
            c.GPU_BLEND_ADD,
            c.GPU_SRC_ALPHA,
            c.GPU_ONE_MINUS_SRC_ALPHA,
            c.GPU_ONE,
            c.GPU_ONE_MINUS_SRC_ALPHA,
        );
    } else {
        c.C3D_AlphaBlend(
            c.GPU_BLEND_ADD,
            c.GPU_BLEND_ADD,
            c.GPU_ONE,
            c.GPU_ZERO,
            c.GPU_ONE,
            c.GPU_ZERO,
        );
    }
}

pub fn set_depth_write(enabled: bool) void {
    depth_write_enabled = enabled;
    if (!initialized) return;
    c.C3D_DepthTest(true, c.GPU_GEQUAL, if (enabled) c.GPU_WRITE_ALL else c.GPU_WRITE_COLOR);
}

pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    fog_enabled = enabled;
    if (!initialized) return;

    if (!enabled) {
        c.C3D_FogGasMode(c.GPU_NO_FOG, c.GPU_PLAIN_DENSITY, false);
        return;
    }

    const safe_end = if (end <= start) start + 0.001 else end;
    const density = 1.0 / @max(0.001, safe_end - start);
    c.FogLut_Exp(&fog_lut, density, 1.0, start, safe_end);
    c.C3D_FogGasMode(c.GPU_FOG, c.GPU_PLAIN_DENSITY, false);
    c.C3D_FogColor(pack_color_rgba(r, g, b, 1.0));
    c.C3D_FogLutBind(&fog_lut);
}

pub fn set_clip_planes(_: bool) void {}

pub fn set_culling(enabled: bool) void {
    cull_face_enabled = enabled;
    if (!initialized) return;
    c.C3D_CullFace(if (enabled) c.GPU_CULL_BACK_CCW else c.GPU_CULL_NONE);
}

pub fn set_uv_offset(u: f32, v: f32) void {
    uv_offset = .{ u, v };
}

pub fn set_proj_matrix(mat: *const Mat4) void {
    proj_matrix = mat.*;
}

pub fn set_view_matrix(mat: *const Mat4) void {
    view_matrix = mat.*;
}

pub fn start_frame() bool {
    const t = target orelse return false;
    const flags: u8 = @intCast(if (vsync_enabled) c.C3D_FRAME_SYNCDRAW else c.C3D_FRAME_NONBLOCK);

    if (!c.C3D_FrameBegin(flags)) return false;
    release_completed_mesh_slots();
    free_deferred_mesh_slots();

    c.C3D_FrameBufClear(target_frame_buf(t), c.C3D_CLEAR_ALL, clear_color, 0);

    if (!c.C3D_FrameDrawOn(t)) {
        c.C3D_FrameEnd(0);
        return false;
    }

    frame_started = true;
    c.C3D_SetViewport(0, 0, TARGET_WIDTH, TARGET_HEIGHT);
    apply_render_state();
    init_texenvs();
    rebind_texture();
    return true;
}

pub fn end_frame() void {
    if (!frame_started) return;
    mark_current_frame_mesh_slots_in_flight();
    c.C3D_FrameEnd(0);
    frame_started = false;
}

pub fn clear_depth() void {
    if (!frame_started) return;
    const t = target orelse return;
    c.C3D_FrameBufClear(target_frame_buf(t), c.C3D_CLEAR_DEPTH, clear_color, 0);
}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
}

fn init_pipeline(layout: vertex.VertexLayout) !PipelineData {
    const code: [:0]align(4) const u8 = &shaders.basic_vert;
    if (layout.stride == 0 or layout.attributes.len > MAX_VERTEX_ATTRS) return error.UnsupportedVertexLayout;

    const dvlb = c.DVLB_ParseFile(@ptrCast(@constCast(code.ptr)), @intCast(code.len));
    if (dvlb == null or dvlb[0].numDVLE == 0) return error.InvalidShader;
    errdefer c.DVLB_Free(dvlb);

    var program: c.shaderProgram_s = undefined;
    if (c.shaderProgramInit(&program) != 0) return error.InvalidShader;
    errdefer _ = c.shaderProgramFree(&program);

    if (c.shaderProgramSetVsh(&program, &dvlb[0].DVLE[0]) != 0) return error.InvalidShader;

    for (layout.attributes) |attr| {
        if (attr.binding != 0) return error.UnsupportedVertexLayout;
    }

    const position_attr = find_attr(layout, .position) orelse return error.UnsupportedVertexLayout;
    const uv_attr = find_attr(layout, .uv) orelse return error.UnsupportedVertexLayout;
    const color_attr = find_attr(layout, .color) orelse return error.UnsupportedVertexLayout;
    const pos_scale = position_scale(position_attr) orelse return error.UnsupportedVertexLayout;
    const uv_attr_scale = uv_scale(uv_attr) orelse return error.UnsupportedVertexLayout;
    const color_attr_scale = color_scale(color_attr) orelse return error.UnsupportedVertexLayout;
    const buffer_layout = buffer_layout_from_attrs(layout.stride, position_attr, uv_attr, color_attr) orelse return error.UnsupportedVertexLayout;

    var attr_info: c.C3D_AttrInfo = undefined;
    c.AttrInfo_Init(&attr_info);
    if (add_attr_loader(&attr_info, 0, position_attr, buffer_layout.position_loader_size) < 0) return error.UnsupportedVertexLayout;
    if (add_attr_loader(&attr_info, 1, uv_attr, buffer_layout.uv_loader_size) < 0) return error.UnsupportedVertexLayout;
    if (add_attr_loader(&attr_info, 2, color_attr, buffer_layout.color_loader_size) < 0) return error.UnsupportedVertexLayout;

    return .{
        .dvlb = dvlb,
        .program = program,
        .attr_info = attr_info,
        .stride = layout.stride,
        .buffer = .{
            .offset = buffer_layout.base_offset,
            .vertex_span = buffer_layout.vertex_span,
            .attrib_count = buffer_layout.attribute_count,
            .permutation = buffer_layout.permutation,
        },
        .pos_scale = pos_scale,
        .uv_scale = uv_attr_scale,
        .color_scale = color_attr_scale,
        .u_projection = c.shaderInstanceGetUniformLocation(program.vertexShader, "projection"),
        .u_model_view = c.shaderInstanceGetUniformLocation(program.vertexShader, "modelView"),
        .u_pos_scale = c.shaderInstanceGetUniformLocation(program.vertexShader, "posScale"),
        .u_uv_scale_offset = c.shaderInstanceGetUniformLocation(program.vertexShader, "uvScaleOffset"),
        .u_color_scale = c.shaderInstanceGetUniformLocation(program.vertexShader, "colorScale"),
    };
}

fn deinit_pipeline(pl: *PipelineData) void {
    _ = c.shaderProgramFree(&pl.program);
    c.DVLB_Free(pl.dvlb);
}

pub fn create_mesh() anyerror!Mesh.Handle {
    const handle = meshes.add_element(.{
        .len = 0,
    }) orelse return error.OutOfMeshes;

    return @intCast(handle);
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    if (mesh_slot(handle)) |mesh| {
        free_mesh_slots(mesh);
    }
    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    const mesh = mesh_slot(handle) orelse return;
    if (data.len > std.math.maxInt(u32)) {
        std.debug.panic("3ds_gfx: mesh vertex data is too large to flush", .{});
    }

    if (data.len == 0) {
        mesh.latest_slot = null;
        mesh.len = 0;
        return;
    }

    const slot_idx = select_upload_slot(mesh) orelse
        std.debug.panic("3ds_gfx: update_mesh called while both 3DS mesh upload slots are in use", .{});
    const slot = &mesh.slots[slot_idx];
    ensure_mesh_slot_capacity(slot, data.len) catch
        std.debug.panic("3ds_gfx: out of linear memory for mesh upload", .{});

    const dst = slot.data.?;
    @memcpy(dst[0..data.len], data);
    slot.len = data.len;
    _ = c.GSPGPU_FlushDataCache(dst.ptr, @intCast(data.len));

    mesh.latest_slot = slot_idx;
    mesh.len = data.len;
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize) void {
    if (!render_pipeline_initialized) return;
    const mesh = mesh_slot(handle) orelse return;
    const pl = &render_pipeline;
    const slot_idx = mesh.latest_slot orelse return;
    const slot = &mesh.slots[slot_idx];
    const data = slot.data orelse return;
    if (count == 0 or slot.len == 0) return;

    const needed = mesh_draw_bytes_needed(pl, count) orelse return;
    if (needed > slot.len) return;

    bind_vertex_state(pl);
    upload_draw_uniforms(pl, model);
    rebind_texture();

    const buf = c.C3D_GetBufInfo() orelse return;
    c.BufInfo_Init(buf);
    const ptr = @as([*]const u8, data.ptr) + pl.buffer.offset;
    const added = c.BufInfo_Add(buf, ptr, @intCast(pl.stride), pl.buffer.attrib_count, pl.buffer.permutation);
    if (added < 0) {
        c.BufInfo_Init(buf);
        return;
    }

    slot.used_this_frame = true;
    c.C3D_DrawArrays(c.GPU_TRIANGLES, 0, @intCast(count));
}

pub fn create_texture(width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle {
    try validate_texture(width, height, data);

    const size = texture_size(width, height);
    if (c.vramSpaceFree() < size) return error.OutOfTextureMemory;

    const mem = c.vramAlloc(size) orelse return error.OutOfTextureMemory;
    errdefer c.vramFree(mem);

    var tex = TextureData{
        .width = width,
        .height = height,
        .tex = init_tex_mirror(width, height, mem, size),
    };
    errdefer free_texture_staging(&tex);

    try upload_texture_data(&tex, data[0..size]);

    const handle = textures.add_element(tex) orelse return error.OutOfTextures;
    return @intCast(handle);
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const tex = texture_slot(handle) orelse return;
    const size = texture_size(tex.width, tex.height);
    if (data.len < size) return;
    if (!is_linear_fcram(data.ptr, size)) {
        std.debug.panic("3ds_gfx: texture upload data must be allocated in linear FCRAM", .{});
    }

    upload_texture_data(tex, data[0..size]) catch return;
}

pub fn bind_texture(handle: Texture.Handle) void {
    bound_texture = handle;
    rebind_texture();
}

pub fn destroy_texture(handle: Texture.Handle) void {
    if (texture_slot(handle)) |tex| {
        c.C3D_TexDelete(tex_ptr(tex));
        free_texture_staging(tex);
    }
    if (bound_texture == handle) {
        bound_texture = 0;
        if (initialized) c.C3D_TexBind(0, null);
    }
    _ = textures.remove_element(handle);
}

pub fn force_texture_resident(_: Texture.Handle) void {}

fn select_upload_slot(mesh: *const MeshData) ?usize {
    if (mesh.latest_slot) |idx| {
        const slot = mesh.slots[idx];
        if (!slot.in_flight and !slot.used_this_frame) return idx;
    }

    for (0..MESH_SLOT_COUNT) |idx| {
        const slot = mesh.slots[idx];
        if (!slot.in_flight and !slot.used_this_frame) return idx;
    }

    return null;
}

fn ensure_mesh_slot_capacity(slot: *MeshSlot, len: usize) !void {
    if (slot.data) |buf| {
        if (buf.len >= len) return;
    }

    const cap = mesh_slot_capacity(len);
    const new_data = try render_alloc.alignedAlloc(u8, .fromByteUnits(16), cap);

    if (!is_linear_fcram(new_data.ptr, new_data.len)) {
        render_alloc.free(new_data);
        std.debug.panic("3ds_gfx: mesh upload slots must be allocated in linear FCRAM", .{});
    }

    if (slot.data) |old| render_alloc.free(old);
    slot.data = new_data;
    slot.len = 0;
}

fn mesh_slot_capacity(len: usize) usize {
    return @max(len, 256);
}

fn free_mesh_slots(mesh: *MeshData) void {
    for (&mesh.slots) |*slot| free_mesh_slot(slot);
    mesh.latest_slot = null;
    mesh.len = 0;
}

fn free_mesh_slot(slot: *MeshSlot) void {
    if (slot.data) |data| {
        if (slot.in_flight or slot.used_this_frame) {
            defer_mesh_free(data);
        } else {
            render_alloc.free(data);
        }
    }
    slot.* = .{};
}

fn defer_mesh_free(data: []align(16) u8) void {
    if (deferred_mesh_frees.add_element(.{ .data = data }) != null) return;
    std.debug.panic("3ds_gfx: deferred mesh free queue exhausted", .{});
}

fn free_deferred_mesh_slots() void {
    for (1..deferred_mesh_frees.buffer.len) |i| {
        if (deferred_mesh_frees.buffer[i]) |free| {
            render_alloc.free(free.data);
        }
    }
    deferred_mesh_frees.clear();
}

fn release_completed_mesh_slots() void {
    for (1..meshes.buffer.len) |i| {
        if (meshes.buffer[i]) |*mesh| {
            for (&mesh.slots) |*slot| {
                slot.in_flight = false;
                slot.used_this_frame = false;
            }
        }
    }
}

fn mark_current_frame_mesh_slots_in_flight() void {
    for (1..meshes.buffer.len) |i| {
        if (meshes.buffer[i]) |*mesh| {
            for (&mesh.slots) |*slot| {
                if (slot.used_this_frame) {
                    slot.in_flight = true;
                    slot.used_this_frame = false;
                }
            }
        }
    }
}

fn mesh_draw_bytes_needed(pl: *const PipelineData, count: usize) ?usize {
    if (count == 0) return 0;

    const tail_count = count - 1;
    const max = std.math.maxInt(usize);
    if (pl.stride != 0 and tail_count > (max - pl.buffer.vertex_span) / pl.stride) return null;

    const rel_end = tail_count * pl.stride + pl.buffer.vertex_span;
    if (pl.buffer.offset > max - rel_end) return null;
    return pl.buffer.offset + rel_end;
}

fn apply_render_state() void {
    set_alpha_blend(alpha_blend_enabled);
    set_depth_write(depth_write_enabled);
    set_culling(cull_face_enabled);
    if (!fog_enabled) {
        c.C3D_FogGasMode(c.GPU_NO_FOG, c.GPU_PLAIN_DENSITY, false);
    }
}

fn init_texenvs() void {
    texenv_modulate(0);
    var i: c_int = 1;
    while (i < 6) : (i += 1) texenv_replace_previous(i);
}

fn texenv_modulate(id: c_int) void {
    const env = c.C3D_GetTexEnv(id) orelse return;
    const mirror: *TexEnvMirror = @ptrCast(@alignCast(env));
    const sources: u16 = @intCast(c.GPU_TEVSOURCES(c.GPU_TEXTURE0, c.GPU_PRIMARY_COLOR, 0));
    mirror.* = .{
        .src_rgb = sources,
        .src_alpha = sources,
        .op_all = 0,
        .func_rgb = @intCast(c.GPU_MODULATE),
        .func_alpha = @intCast(c.GPU_MODULATE),
        .color = 0xffffffff,
        .scale_rgb = @intCast(c.GPU_TEVSCALE_1),
        .scale_alpha = @intCast(c.GPU_TEVSCALE_1),
    };
    c.C3D_DirtyTexEnv(env);
}

fn texenv_replace_previous(id: c_int) void {
    const env = c.C3D_GetTexEnv(id) orelse return;
    const mirror: *TexEnvMirror = @ptrCast(@alignCast(env));
    const sources: u16 = @intCast(c.GPU_TEVSOURCES(c.GPU_PREVIOUS, 0, 0));
    mirror.* = .{
        .src_rgb = sources,
        .src_alpha = sources,
        .op_all = 0,
        .func_rgb = @intCast(c.GPU_REPLACE),
        .func_alpha = @intCast(c.GPU_REPLACE),
        .color = 0xffffffff,
        .scale_rgb = @intCast(c.GPU_TEVSCALE_1),
        .scale_alpha = @intCast(c.GPU_TEVSCALE_1),
    };
    c.C3D_DirtyTexEnv(env);
}

fn bind_vertex_state(pl: *PipelineData) void {
    c.C3D_BindProgram(&pl.program);
    c.C3D_SetAttrInfo(&pl.attr_info);
}

fn init_projection_transform() void {
    var screen: c.C3D_Mtx = undefined;
    c.Mtx_OrthoTilt(&screen, 0.0, @floatFromInt(SCREEN_WIDTH), 0.0, @floatFromInt(SCREEN_HEIGHT), 0.0, 1.0, true);
    var viewport = logical_viewport_transform();
    projection_transform = c3d_mtx_mul(&screen, &viewport);
}

fn logical_viewport_transform() c.C3D_Mtx {
    var out: c.C3D_Mtx = undefined;
    set_fvec(&out.r[0], @as(f32, @floatFromInt(SCREEN_WIDTH)) * 0.5, 0.0, 0.0, @as(f32, @floatFromInt(SCREEN_WIDTH)) * 0.5);
    set_fvec(&out.r[1], 0.0, @as(f32, @floatFromInt(SCREEN_HEIGHT)) * 0.5, 0.0, @as(f32, @floatFromInt(SCREEN_HEIGHT)) * 0.5);
    set_fvec(&out.r[2], 0.0, 0.0, -1.0, 1.0);
    set_fvec(&out.r[3], 0.0, 0.0, 0.0, 1.0);
    return out;
}

fn upload_draw_uniforms(pl: *PipelineData, model: *const Mat4) void {
    var aether_projection = mat4_to_c3d_transposed(proj_matrix);
    var projection = c3d_mtx_mul(&projection_transform, &aether_projection);
    const model_view = Mat4.mul(model.*, view_matrix);
    var model_view_c3d = mat4_to_c3d_transposed(model_view);

    upload_matrix(pl.u_projection, &projection);
    upload_matrix(pl.u_model_view, &model_view_c3d);
    upload_vec4(pl.u_pos_scale, pl.pos_scale);
    upload_vec4(pl.u_uv_scale_offset, .{
        pl.uv_scale[0],
        pl.uv_scale[1],
        uv_offset[0],
        uv_offset[1],
    });
    upload_vec4(pl.u_color_scale, pl.color_scale);
}

fn upload_matrix(location: c_int, matrix: *const c.C3D_Mtx) void {
    const idx = uniform_location(location, 4) orelse return;
    inline for (0..4) |i| {
        c.C3D_FVUnif[VERTEX_SHADER_INDEX][idx + i] = matrix.r[i];
        c.C3D_FVUnifDirty[VERTEX_SHADER_INDEX][idx + i] = true;
    }
}

fn upload_vec4(location: c_int, values: [4]f32) void {
    const idx = uniform_location(location, 1) orelse return;
    set_fvec(&c.C3D_FVUnif[VERTEX_SHADER_INDEX][idx], values[0], values[1], values[2], values[3]);
    c.C3D_FVUnifDirty[VERTEX_SHADER_INDEX][idx] = true;
}

fn uniform_location(location: c_int, count: usize) ?usize {
    if (location < 0) return null;
    const idx: usize = @intCast(location);
    if (idx + count > c.C3D_FVUNIF_COUNT) return null;
    return idx;
}

fn mat4_to_c3d_transposed(mat: Mat4) c.C3D_Mtx {
    var out: c.C3D_Mtx = undefined;
    inline for (0..4) |row| {
        set_fvec(&out.r[row], mat.data[0][row], mat.data[1][row], mat.data[2][row], mat.data[3][row]);
    }
    return out;
}

fn c3d_mtx_mul(a: *const c.C3D_Mtx, b: *const c.C3D_Mtx) c.C3D_Mtx {
    var out: c.C3D_Mtx = undefined;
    inline for (0..4) |row| {
        var values: [4]f32 = undefined;
        inline for (0..4) |col| {
            var sum: f32 = 0.0;
            inline for (0..4) |k| {
                sum += fvec_component(&a.r[row], k) * fvec_component(&b.r[k], col);
            }
            values[col] = sum;
        }
        set_fvec(&out.r[row], values[0], values[1], values[2], values[3]);
    }
    return out;
}

fn fvec_component(v: *const c.C3D_FVec, index: usize) f32 {
    return switch (index) {
        0 => v.unnamed_0.x,
        1 => v.unnamed_0.y,
        2 => v.unnamed_0.z,
        3 => v.unnamed_0.w,
        else => unreachable,
    };
}

fn set_fvec(v: *c.C3D_FVec, x: f32, y: f32, z: f32, w: f32) void {
    v.unnamed_0.x = x;
    v.unnamed_0.y = y;
    v.unnamed_0.z = z;
    v.unnamed_0.w = w;
}

fn rebind_texture() void {
    if (!initialized or bound_texture == 0) return;
    const tex = texture_slot(bound_texture) orelse return;
    c.C3D_TexBind(0, tex_ptr(tex));
}

fn validate_texture(width: u32, height: u32, data: []align(16) u8) !void {
    if (width < MIN_TEXTURE_SIZE or height < MIN_TEXTURE_SIZE) {
        Util.engine_logger.err("3ds_gfx: texture {d}x{d} is too small; Citro3D requires at least {d}x{d}", .{
            width,
            height,
            MIN_TEXTURE_SIZE,
            MIN_TEXTURE_SIZE,
        });
        return error.TextureTooSmall;
    }
    if (width > MAX_TEXTURE_SIZE or height > MAX_TEXTURE_SIZE) {
        Util.engine_logger.err("3ds_gfx: texture {d}x{d} is too large; Citro3D limit is {d}x{d}", .{
            width,
            height,
            MAX_TEXTURE_SIZE,
            MAX_TEXTURE_SIZE,
        });
        return error.TextureTooLarge;
    }
    if (!std.math.isPowerOfTwo(width) or !std.math.isPowerOfTwo(height)) {
        Util.engine_logger.err("3ds_gfx: texture {d}x{d} is unsupported; Citro3D requires power-of-two dimensions", .{ width, height });
        return error.UnsupportedTextureSize;
    }

    const size = texture_size(width, height);
    if (data.len < size) return error.InsufficientData;
    if (!is_linear_fcram(data.ptr, size)) {
        Util.engine_logger.err("3ds_gfx: texture upload data must be allocated in linear FCRAM", .{});
        return error.TextureDataNotLinear;
    }
    if (size > std.math.maxInt(u32)) return error.TextureTooLarge;
}

fn init_tex_mirror(width: u32, height: u32, data: ?*anyopaque, size: u32) TexMirror {
    return .{
        .data = data,
        .fmt_size = (size << 4) | @as(u32, @intCast(c.GPU_RGBA8)),
        .dim = (width << 16) | height,
        .param = texture_param(),
        .border = 0,
        .lod_param = 0,
    };
}

fn texture_param() u32 {
    return @intCast(
        c.GPU_TEXTURE_MODE(c.GPU_TEX_2D) |
            c.GPU_TEXTURE_MAG_FILTER(c.GPU_NEAREST) |
            c.GPU_TEXTURE_MIN_FILTER(c.GPU_NEAREST) |
            c.GPU_TEXTURE_WRAP_S(c.GPU_REPEAT) |
            c.GPU_TEXTURE_WRAP_T(c.GPU_REPEAT),
    );
}

fn upload_texture_data(tex: *TextureData, data: []align(16) const u8) !void {
    const size = texture_size(tex.width, tex.height);
    const upload = try ensure_texture_staging(tex, size);

    convert_texture_data(upload, data, tex.width, tex.height);
    flush_texture_source(upload);
    c.C3D_TexLoadImage(tex_ptr(tex), upload.ptr, c.GPU_TEXFACE_2D, 0);
    c.C3D_TexFlush(tex_ptr(tex));
}

fn ensure_texture_staging(tex: *TextureData, size: usize) ![]align(16) u8 {
    if (tex.staging) |buf| {
        if (buf.len >= size) return buf[0..size];
        render_alloc.free(buf);
        tex.staging = null;
    }

    const staging = try render_alloc.alignedAlloc(u8, .fromByteUnits(16), size);
    if (!is_linear_fcram(staging.ptr, staging.len)) {
        render_alloc.free(staging);
        std.debug.panic("3ds_gfx: texture staging must be allocated in linear FCRAM", .{});
    }

    tex.staging = staging;
    return staging;
}

fn free_texture_staging(tex: *TextureData) void {
    if (tex.staging) |staging| {
        render_alloc.free(staging);
        tex.staging = null;
    }
}

fn convert_texture_data(dst: []align(16) u8, src: []align(16) const u8, width: u32, height: u32) void {
    for (0..height) |y| {
        const sy = height - 1 - @as(u32, @intCast(y));
        for (0..width) |x| {
            const xu: u32 = @intCast(x);
            const src_off = (@as(usize, sy) * width + xu) * TEX_BPP;
            const dst_off = tiled_pixel_offset(xu, @intCast(y), width) * TEX_BPP;
            dst[dst_off + 0] = src[src_off + 3];
            dst[dst_off + 1] = src[src_off + 2];
            dst[dst_off + 2] = src[src_off + 1];
            dst[dst_off + 3] = src[src_off + 0];
        }
    }
}

fn tiled_pixel_offset(x: u32, y: u32, width: u32) usize {
    const tile_x = x & ~@as(u32, 7);
    const tile_y = y & ~@as(u32, 7);
    const tile_base = tile_y * width + tile_x * 8;
    return @intCast(tile_base + morton8(x & 7, y & 7));
}

fn morton8(x: u32, y: u32) u32 {
    return (x & 1) |
        ((y & 1) << 1) |
        ((x & 2) << 1) |
        ((y & 2) << 2) |
        ((x & 4) << 2) |
        ((y & 4) << 3);
}

fn flush_texture_source(data: []align(16) u8) void {
    _ = c.GSPGPU_FlushDataCache(data.ptr, @intCast(data.len));
}

fn texture_size(width: u32, height: u32) u32 {
    return @intCast(@as(usize, width) * height * TEX_BPP);
}

fn tex_ptr(tex: *TextureData) *c.C3D_Tex {
    return @ptrCast(&tex.tex);
}

fn target_frame_buf(t: *c.C3D_RenderTarget) *c.C3D_FrameBuf {
    const mirror: *RenderTargetMirror = @ptrCast(@alignCast(t));
    return @ptrCast(&mirror.frame_buf);
}

fn mesh_slot(handle: Mesh.Handle) ?*MeshData {
    const idx: usize = handle;
    if (idx == 0 or idx >= meshes.buffer.len) return null;
    if (meshes.buffer[idx]) |*mesh| return mesh;
    return null;
}

fn texture_slot(handle: Texture.Handle) ?*TextureData {
    const idx: usize = handle;
    if (idx == 0 or idx >= textures.buffer.len) return null;
    if (textures.buffer[idx]) |*tex| return tex;
    return null;
}

fn find_attr(layout: vertex.VertexLayout, usage: vertex.AttributeUsage) ?vertex.Attribute {
    for (layout.attributes) |attr| {
        if (attr.usage == usage) return attr;
    }
    return null;
}

const BufferLayout = struct {
    base_offset: usize,
    vertex_span: usize,
    attribute_count: c_int,
    permutation: u64,
    position_loader_size: u8,
    uv_loader_size: u8,
    color_loader_size: u8,
};

fn buffer_layout_from_attrs(stride: usize, position_attr: vertex.Attribute, uv_attr: vertex.Attribute, color_attr: vertex.Attribute) ?BufferLayout {
    var attrs = [_]vertex.Attribute{ position_attr, uv_attr, color_attr };
    sort_attrs_by_offset(&attrs);

    const base_offset = attrs[0].offset;
    var current_rel: usize = 0;
    var attribute_count: usize = 0;
    var permutation: u64 = 0;
    var position_loader_size: u8 = 0;
    var uv_loader_size: u8 = 0;
    var color_loader_size: u8 = 0;

    for (attrs, 0..) |attr, i| {
        if (!attr_fits(stride, attr)) return null;
        if (attr.offset < base_offset) return null;
        const rel_offset = attr.offset - base_offset;
        if (rel_offset != current_rel) return null;

        const next_offset = if (i + 1 < attrs.len) attrs[i + 1].offset else stride;
        if (next_offset < attr.offset) return null;
        const available_bytes = next_offset - attr.offset;
        const loader_size = attribute_loader_size(attr, available_bytes) orelse return null;
        const loaded_bytes = attribute_size_bytes_with_count(attr.format, loader_size) orelse return null;
        if (loaded_bytes > available_bytes) return null;
        if (i + 1 < attrs.len and loaded_bytes != available_bytes) return null;

        permutation |= attribute_loader_id(attr.usage) << @as(u6, @intCast(attribute_count * 4));
        attribute_count += 1;
        switch (attr.usage) {
            .position => position_loader_size = loader_size,
            .uv => uv_loader_size = loader_size,
            .color => color_loader_size = loader_size,
            .normal => return null,
        }
        current_rel = rel_offset + loaded_bytes;
    }

    if (stride < current_rel) return null;
    if (position_loader_size == 0 or uv_loader_size == 0 or color_loader_size == 0) return null;

    return .{
        .base_offset = base_offset,
        .vertex_span = current_rel,
        .attribute_count = @intCast(attribute_count),
        .permutation = permutation,
        .position_loader_size = position_loader_size,
        .uv_loader_size = uv_loader_size,
        .color_loader_size = color_loader_size,
    };
}

fn sort_attrs_by_offset(attrs: *[3]vertex.Attribute) void {
    var i: usize = 1;
    while (i < attrs.len) : (i += 1) {
        var j = i;
        while (j > 0 and attrs[j - 1].offset > attrs[j].offset) : (j -= 1) {
            const tmp = attrs[j - 1];
            attrs[j - 1] = attrs[j];
            attrs[j] = tmp;
        }
    }
}

fn attribute_loader_id(usage: vertex.AttributeUsage) u64 {
    return switch (usage) {
        .position => 0,
        .uv => 1,
        .color => 2,
        .normal => unreachable,
    };
}

fn attr_fits(stride: usize, attr: vertex.Attribute) bool {
    const size = attribute_size_bytes(attr.format);
    return attr.offset <= stride and size <= stride - attr.offset;
}

fn attribute_loader_size(attr: vertex.Attribute, available_bytes: usize) ?u8 {
    if (attr.usage == .position and attr.size == 3 and attribute_component_size_bytes(attr.format) == 2 and available_bytes >= 8) {
        return 4;
    }
    if (attr.size == 0 or attr.size > 4) return null;
    return @intCast(attr.size);
}

fn attribute_size_bytes(format: vertex.AttributeFormat) usize {
    return switch (format) {
        .f32x2 => 8,
        .f32x3 => 12,
        .unorm8x2 => 2,
        .unorm8x4 => 4,
        .unorm16x2, .snorm16x2 => 4,
        .unorm16x3, .snorm16x3 => 6,
    };
}

fn attribute_size_bytes_with_count(format: vertex.AttributeFormat, count: u8) ?usize {
    if (count == 0 or count > 4) return null;
    return attribute_component_size_bytes(format) * @as(usize, count);
}

fn attribute_component_size_bytes(format: vertex.AttributeFormat) usize {
    return switch (format) {
        .f32x2, .f32x3 => 4,
        .unorm8x2, .unorm8x4 => 1,
        .unorm16x2, .unorm16x3, .snorm16x2, .snorm16x3 => 2,
    };
}

fn gpu_format(format: vertex.AttributeFormat) c.GPU_FORMATS {
    return switch (format) {
        .f32x2, .f32x3 => c.GPU_FLOAT,
        .unorm8x2, .unorm8x4 => c.GPU_UNSIGNED_BYTE,
        .unorm16x2, .unorm16x3, .snorm16x2, .snorm16x3 => c.GPU_SHORT,
    };
}

fn add_attr_loader(info: *c.C3D_AttrInfo, reg_id: c_int, attr: vertex.Attribute, loader_size: u8) c_int {
    return c.AttrInfo_AddLoader(info, reg_id, gpu_format(attr.format), loader_size);
}

fn position_scale(attr: vertex.Attribute) ?[4]f32 {
    if (attr.size != 3) return null;
    return switch (attr.format) {
        .f32x3 => .{ 1.0, 1.0, 1.0, 1.0 },
        .snorm16x3 => .{ snorm16_scale(), snorm16_scale(), snorm16_scale(), 1.0 },
        else => null,
    };
}

fn uv_scale(attr: vertex.Attribute) ?[2]f32 {
    if (attr.size != 2) return null;
    return switch (attr.format) {
        .f32x2 => .{ 1.0, 1.0 },
        .unorm8x2 => .{ unorm8_scale(), unorm8_scale() },
        .snorm16x2 => .{ snorm16_scale(), snorm16_scale() },
        else => null,
    };
}

fn color_scale(attr: vertex.Attribute) ?[4]f32 {
    if (attr.size != 4) return null;
    return switch (attr.format) {
        .unorm8x4 => .{ unorm8_scale(), unorm8_scale(), unorm8_scale(), unorm8_scale() },
        .f32x3 => .{ 1.0, 1.0, 1.0, 1.0 },
        else => null,
    };
}

fn unorm8_scale() f32 {
    return 1.0 / 255.0;
}

fn snorm16_scale() f32 {
    return 1.0 / 32767.0;
}

fn is_linear_fcram(ptr: [*]const u8, len: usize) bool {
    const start = @intFromPtr(ptr);
    return in_range(start, len, OS_FCRAM_VADDR, OS_FCRAM_SIZE) or
        in_range(start, len, OS_OLD_FCRAM_VADDR, OS_OLD_FCRAM_SIZE);
}

fn in_range(start: usize, len: usize, base: usize, size: usize) bool {
    if (start < base) return false;
    const offset = start - base;
    return offset <= size and len <= size - offset;
}

fn float_to_u8(v: f32) u8 {
    return @intFromFloat(@max(0.0, @min(1.0, v)) * 255.0);
}

fn pack_color_rgba(r: f32, g: f32, b: f32, a: f32) u32 {
    const ri: u32 = float_to_u8(r);
    const gi: u32 = float_to_u8(g);
    const bi: u32 = float_to_u8(b);
    const ai: u32 = float_to_u8(a);
    return (ri << 24) | (gi << 16) | (bi << 8) | ai;
}
