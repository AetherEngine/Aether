//! Citro3D graphics backend for Nintendo 3DS.

const std = @import("std");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const surface = @import("surface.zig");
const shaders = @import("aether_shaders");

const c = @cImport({
    @cDefine("wint_t", "unsigned int");
    @cInclude("3ds/types.h");
    @cInclude("3ds/gpu/enums.h");
    @cInclude("3ds/gpu/gpu.h");
    @cInclude("3ds/gpu/gx.h");
    @cInclude("3ds/os.h");
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
const MESH_SLOT_COUNT: usize = 2;
const MAX_DEFERRED_MESH_FREES: usize = 4096;
const C3D_CMD_BUFFER_SIZE: usize = 1024 * 1024;
const MAX_TEXTURE_SIZE: u32 = 1024;
const MIN_TEXTURE_SIZE: u32 = 8;
const TEX_BPP: usize = 4;
const CACHE_LINE_SIZE: usize = 32;
const OS_FCRAM_VADDR: usize = 0x30000000;
const OS_FCRAM_SIZE: usize = 0x10000000;
const OS_OLD_FCRAM_VADDR: usize = 0x14000000;
const OS_OLD_FCRAM_SIZE: usize = 0x08000000;
const BUFFER_BASE_PADDR: u32 = 0x18000000;
const SH_MODE_VSH: u32 = 0xA0000000;
const FLOAT_UNIFORM_UPLOAD_F32: u32 = 0x80000000;

const DISPLAY_TRANSFER_FLAGS: u32 = @intCast(
    c.GX_TRANSFER_FLIP_VERT(0) |
        c.GX_TRANSFER_OUT_TILED(0) |
        c.GX_TRANSFER_RAW_COPY(0) |
        c.GX_TRANSFER_IN_FORMAT(c.GX_TRANSFER_FMT_RGBA8) |
        c.GX_TRANSFER_OUT_FORMAT(c.GX_TRANSFER_FMT_RGB8) |
        c.GX_TRANSFER_SCALING(c.GX_TRANSFER_SCALE_NO),
);

const VERTEX_SHADER_INDEX: usize = 0;
const VERTEX_STRIDE: usize = @sizeOf(Rendering.Vertex);
const VERTEX_ATTR_COUNT: c_int = 3;
const VERTEX_BUFFER_PERMUTATION: u64 = 0x210; // buffer order pos,color,uv -> shader v0,v1,v2
const VERTEX_POSITION_REG: c_int = 0;
const VERTEX_COLOR_REG: c_int = 1;
const VERTEX_UV_REG: c_int = 2;
const POS_SCALE: [4]f32 = .{ snorm16_scale(), snorm16_scale(), snorm16_scale(), 1.0 };
const UV_SCALE: [2]f32 = .{ snorm16_scale(), snorm16_scale() };
const COLOR_SCALE: [4]f32 = .{ unorm8_scale(), unorm8_scale(), unorm8_scale(), unorm8_scale() };

extern fn C3Di_UpdateContext() void;

comptime {
    std.debug.assert(VERTEX_STRIDE == 16);
    std.debug.assert(@offsetOf(Rendering.Vertex, "pos") == 0);
    std.debug.assert(@offsetOf(Rendering.Vertex, "color") == 8);
    std.debug.assert(@offsetOf(Rendering.Vertex, "uv") == 12);
}

const PipelineData = struct {
    dvlb: [*c]c.DVLB_s,
    program: c.shaderProgram_s,
    attr_info: c.C3D_AttrInfo,
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
    staging: ?[]align(16) u32 = null,
};

var meshes = Util.CircularBuffer(MeshData, 2048).init();
var deferred_mesh_frees = Util.CircularBuffer(DeferredMeshFree, MAX_DEFERRED_MESH_FREES + 1).init();
var textures = Util.CircularBuffer(TextureData, 64).init();
var sequential_indices: ?[]align(CACHE_LINE_SIZE) u16 = null;
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
    render_pipeline = try init_pipeline();
    render_pipeline_initialized = true;

    initialized = true;
    frame_started = false;
    apply_render_state();
}

pub fn deinit() void {
    if (surface.is_system_closing()) {
        abandon_service_resources();
        return;
    }

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
    free_index_buffer();

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
    if (surface.is_system_closing()) return false;

    const t = target orelse return false;
    const flags: u8 = @intCast(if (vsync_enabled) c.C3D_FRAME_SYNCDRAW else c.C3D_FRAME_NONBLOCK);

    if (!c.C3D_FrameBegin(flags)) return false;
    release_completed_mesh_slots();
    free_deferred_mesh_slots();

    if (!c.C3D_FrameDrawOn(t)) {
        c.C3D_FrameEnd(0);
        return false;
    }

    frame_started = true;
    clear_current_framebuffer(c.C3D_CLEAR_ALL);
    c.C3D_SetViewport(0, 0, TARGET_WIDTH, TARGET_HEIGHT);
    apply_render_state();
    rebind_texture();
    return true;
}

pub fn end_frame() void {
    if (!frame_started) return;
    if (surface.is_system_closing()) {
        frame_started = false;
        return;
    }
    mark_current_frame_mesh_slots_in_flight();
    finish_frame_direct();
    c.C3D_FrameEnd(0);
    frame_started = false;
}

pub fn clear_depth() void {
    if (!frame_started) return;
    clear_current_framebuffer(c.C3D_CLEAR_DEPTH);
}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
}

fn init_pipeline() !PipelineData {
    const code: [:0]align(4) const u8 = &shaders.basic_vert;

    const dvlb = c.DVLB_ParseFile(@ptrCast(@constCast(code.ptr)), @intCast(code.len));
    if (dvlb == null or dvlb[0].numDVLE == 0) return error.InvalidShader;
    errdefer c.DVLB_Free(dvlb);

    var program: c.shaderProgram_s = undefined;
    if (c.shaderProgramInit(&program) != 0) return error.InvalidShader;
    errdefer _ = c.shaderProgramFree(&program);

    if (c.shaderProgramSetVsh(&program, &dvlb[0].DVLE[0]) != 0) return error.InvalidShader;

    var attr_info: c.C3D_AttrInfo = undefined;
    c.AttrInfo_Init(&attr_info);
    if (c.AttrInfo_AddLoader(&attr_info, VERTEX_POSITION_REG, c.GPU_SHORT, 4) < 0) return error.UnsupportedVertexLayout;
    if (c.AttrInfo_AddLoader(&attr_info, VERTEX_COLOR_REG, c.GPU_UNSIGNED_BYTE, 4) < 0) return error.UnsupportedVertexLayout;
    if (c.AttrInfo_AddLoader(&attr_info, VERTEX_UV_REG, c.GPU_SHORT, 2) < 0) return error.UnsupportedVertexLayout;

    return .{
        .dvlb = dvlb,
        .program = program,
        .attr_info = attr_info,
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
    if (surface.is_system_closing()) {
        _ = meshes.remove_element(handle);
        return;
    }

    if (mesh_slot(handle)) |mesh| {
        free_mesh_slots(mesh);
    }
    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    if (surface.is_system_closing()) return;

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
    flush_data_cache(dst.ptr, data.len);

    mesh.latest_slot = slot_idx;
    mesh.len = data.len;
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize) void {
    if (surface.is_system_closing()) return;

    if (!render_pipeline_initialized) return;
    const mesh = mesh_slot(handle) orelse return;
    const pl = &render_pipeline;
    const slot_idx = mesh.latest_slot orelse return;
    const slot = &mesh.slots[slot_idx];
    const data = slot.data orelse return;
    if (count == 0 or slot.len == 0) return;

    const needed = mesh_draw_bytes_needed(count) orelse return;
    if (needed > slot.len) return;

    bind_program(pl);
    rebind_texture();

    C3Di_UpdateContext();
    upload_draw_uniforms(pl, model);
    bind_texenv_direct();
    bind_vertex_layout_direct(pl);
    if (!bind_vertex_buffer_direct(data.ptr)) return;

    slot.used_this_frame = true;
    if (!draw_elements_direct(count)) {
        draw_arrays_direct(0, @intCast(count));
    }
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
    if (surface.is_system_closing()) return;

    const tex = texture_slot(handle) orelse return;
    const size = texture_size(tex.width, tex.height);
    if (data.len < size) return;
    if (!is_linear_fcram(data.ptr, size)) {
        std.debug.panic("3ds_gfx: texture upload data must be allocated in linear FCRAM", .{});
    }

    upload_texture_data(tex, data[0..size]) catch return;
}

pub fn bind_texture(handle: Texture.Handle) void {
    if (surface.is_system_closing()) return;

    bound_texture = handle;
    rebind_texture();
}

pub fn destroy_texture(handle: Texture.Handle) void {
    if (surface.is_system_closing()) {
        if (bound_texture == handle) bound_texture = 0;
        _ = textures.remove_element(handle);
        return;
    }

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
    const new_data = try render_alloc.alignedAlloc(u8, .fromByteUnits(CACHE_LINE_SIZE), cap);

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

fn abandon_service_resources() void {
    frame_started = false;
    initialized = false;
    render_pipeline_initialized = false;
    target = null;
    bound_texture = 0;
    meshes.clear();
    textures.clear();
    sequential_indices = null;
    deferred_mesh_frees.clear();
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

fn mesh_draw_bytes_needed(count: usize) ?usize {
    if (count == 0) return 0;
    const max = std.math.maxInt(usize);
    if (count > max / VERTEX_STRIDE) return null;
    return count * VERTEX_STRIDE;
}

fn clear_current_framebuffer(bits: c.C3D_ClearBits) void {
    const fb = c.C3D_GetFrameBuf() orelse return;
    c.C3D_FrameBufClear(fb, bits, clear_color, 0);
}

fn apply_render_state() void {
    set_alpha_blend(alpha_blend_enabled);
    set_depth_write(depth_write_enabled);
    set_culling(cull_face_enabled);
    if (!fog_enabled) {
        c.C3D_FogGasMode(c.GPU_NO_FOG, c.GPU_PLAIN_DENSITY, false);
    }
}

fn bind_program(pl: *PipelineData) void {
    c.C3D_BindProgram(&pl.program);
}

fn bind_texenv_direct() void {
    if (bound_texture == 0) {
        bind_texenv_stage_direct(0, c.GPU_TEVSOURCES(c.GPU_PRIMARY_COLOR, 0, 0), c.GPU_REPLACE);
    } else {
        bind_texenv_stage_direct(0, c.GPU_TEVSOURCES(c.GPU_TEXTURE0, c.GPU_PRIMARY_COLOR, 0), c.GPU_MODULATE);
    }

    bind_texenv_stage_direct(1, c.GPU_TEVSOURCES(c.GPU_PREVIOUS, 0, 0), c.GPU_REPLACE);
    bind_texenv_stage_direct(2, c.GPU_TEVSOURCES(c.GPU_PREVIOUS, 0, 0), c.GPU_REPLACE);
    bind_texenv_stage_direct(3, c.GPU_TEVSOURCES(c.GPU_PREVIOUS, 0, 0), c.GPU_REPLACE);
    bind_texenv_stage_direct(4, c.GPU_TEVSOURCES(c.GPU_PREVIOUS, 0, 0), c.GPU_REPLACE);
    bind_texenv_stage_direct(5, c.GPU_TEVSOURCES(c.GPU_PREVIOUS, 0, 0), c.GPU_REPLACE);
}

fn bind_texenv_stage_direct(stage: c_int, source: u32, combiner: u32) void {
    const source_both = source | (source << 16);
    const combiner_both = combiner | (combiner << 16);
    const regs = [_]u32{
        source_both,
        0,
        combiner_both,
        0xffffffff,
        @as(u32, @intCast(c.GPU_TEVSCALE_1)) | (@as(u32, @intCast(c.GPU_TEVSCALE_1)) << 16),
    };
    gpu_cmd_add_incremental_writes(texenv_source_reg(stage), regs[0..]);
}

fn texenv_source_reg(stage: c_int) c_int {
    return switch (stage) {
        0 => c.GPUREG_TEXENV0_SOURCE,
        1 => c.GPUREG_TEXENV1_SOURCE,
        2 => c.GPUREG_TEXENV2_SOURCE,
        3 => c.GPUREG_TEXENV3_SOURCE,
        4 => c.GPUREG_TEXENV4_SOURCE,
        5 => c.GPUREG_TEXENV5_SOURCE,
        else => unreachable,
    };
}

fn bind_vertex_layout_direct(pl: *const PipelineData) void {
    gpu_cmd_add_write(c.GPUREG_ATTRIBBUFFERS_LOC, BUFFER_BASE_PADDR >> 3);
    gpu_cmd_add_incremental_writes(c.GPUREG_ATTRIBBUFFERS_FORMAT_LOW, pl.attr_info.flags[0..]);
    gpu_cmd_add_write(c.GPUREG_VERTEX_OFFSET, 0);
    gpu_cmd_add_write(c.GPUREG_ATTRIBBUFFER0_CONFIG1, @intCast(VERTEX_BUFFER_PERMUTATION));
    gpu_cmd_add_write(c.GPUREG_ATTRIBBUFFER0_CONFIG2, vertex_buffer_format());
    gpu_cmd_add_write(c.GPUREG_VSH_ATTRIBUTES_PERMUTATION_LOW, @intCast(VERTEX_BUFFER_PERMUTATION));
    gpu_cmd_add_write(c.GPUREG_VSH_ATTRIBUTES_PERMUTATION_HIGH, 0);
    set_vsh_input_count_direct(VERTEX_ATTR_COUNT);
}

fn bind_vertex_buffer_direct(data: [*]align(16) const u8) bool {
    const phys = c.osConvertVirtToPhys(data);
    if (phys < BUFFER_BASE_PADDR) return false;
    gpu_cmd_add_write(c.GPUREG_ATTRIBBUFFER0_OFFSET, phys - BUFFER_BASE_PADDR);
    return true;
}

fn draw_elements_direct(count: usize) bool {
    const indices = ensure_index_buffer(count) catch return false;
    const phys = c.osConvertVirtToPhys(indices.ptr);
    if (phys < BUFFER_BASE_PADDR) return false;

    gpu_cmd_add_write(c.GPUREG_INDEXBUFFER_CONFIG, (phys - BUFFER_BASE_PADDR) | (1 << 31));
    gpu_cmd_add_masked_write(c.GPUREG_PRIMITIVE_CONFIG, 2, @intCast(c.GPU_GEOMETRY_PRIM));
    gpu_cmd_add_write(c.GPUREG_RESTART_PRIMITIVE, 1);
    gpu_cmd_add_write(c.GPUREG_NUMVERTICES, @intCast(count));
    gpu_cmd_add_write(c.GPUREG_VERTEX_OFFSET, 0);
    gpu_cmd_add_masked_write(c.GPUREG_GEOSTAGE_CONFIG, 2, 0x100);
    gpu_cmd_add_masked_write(c.GPUREG_GEOSTAGE_CONFIG2, 2, 0x100);
    gpu_cmd_add_masked_write(c.GPUREG_START_DRAW_FUNC0, 1, 0);
    gpu_cmd_add_write(c.GPUREG_DRAWELEMENTS, 1);
    gpu_cmd_add_masked_write(c.GPUREG_START_DRAW_FUNC0, 1, 1);
    gpu_cmd_add_masked_write(c.GPUREG_GEOSTAGE_CONFIG, 2, 0);
    gpu_cmd_add_masked_write(c.GPUREG_GEOSTAGE_CONFIG2, 2, 0);
    gpu_cmd_add_write(c.GPUREG_VTX_FUNC, 1);
    gpu_cmd_add_masked_write(c.GPUREG_PRIMITIVE_CONFIG, 0x8, 0);
    gpu_cmd_add_masked_write(c.GPUREG_PRIMITIVE_CONFIG, 0x8, 0);
    return true;
}

fn draw_arrays_direct(first: u32, count: u32) void {
    gpu_cmd_add_masked_write(c.GPUREG_PRIMITIVE_CONFIG, 2, @intCast(c.GPU_TRIANGLES));
    gpu_cmd_add_write(c.GPUREG_RESTART_PRIMITIVE, 1);
    gpu_cmd_add_write(c.GPUREG_INDEXBUFFER_CONFIG, 0x80000000);
    gpu_cmd_add_write(c.GPUREG_NUMVERTICES, count);
    gpu_cmd_add_write(c.GPUREG_VERTEX_OFFSET, first);
    gpu_cmd_add_masked_write(c.GPUREG_GEOSTAGE_CONFIG2, 1, 1);
    gpu_cmd_add_masked_write(c.GPUREG_START_DRAW_FUNC0, 1, 0);
    gpu_cmd_add_write(c.GPUREG_DRAWARRAYS, 1);
    gpu_cmd_add_masked_write(c.GPUREG_START_DRAW_FUNC0, 1, 1);
    gpu_cmd_add_masked_write(c.GPUREG_GEOSTAGE_CONFIG2, 1, 0);
    gpu_cmd_add_write(c.GPUREG_VTX_FUNC, 1);
}

fn ensure_index_buffer(count: usize) ![]align(CACHE_LINE_SIZE) u16 {
    if (count == 0 or count > std.math.maxInt(u16) + 1) return error.UnsupportedIndexCount;
    if (sequential_indices) |indices| {
        if (indices.len >= count) return indices[0..count];
        render_alloc.free(indices);
        sequential_indices = null;
    }

    const indices = try render_alloc.alignedAlloc(u16, .fromByteUnits(CACHE_LINE_SIZE), count);
    const bytes: [*]const u8 = @ptrCast(indices.ptr);
    if (!is_linear_fcram(bytes, indices.len * @sizeOf(u16))) {
        render_alloc.free(indices);
        return error.IndexBufferNotLinear;
    }

    for (indices, 0..) |*idx, i| idx.* = @intCast(i);
    flush_data_cache(bytes, indices.len * @sizeOf(u16));
    sequential_indices = indices;
    return indices;
}

fn free_index_buffer() void {
    if (sequential_indices) |indices| {
        render_alloc.free(indices);
        sequential_indices = null;
    }
}

fn finish_frame_direct() void {
    gpu_cmd_add_write(c.GPUREG_FRAMEBUFFER_FLUSH, 1);
    gpu_cmd_add_write(c.GPUREG_FRAMEBUFFER_INVALIDATE, 1);
    gpu_cmd_add_write(c.GPUREG_EARLYDEPTH_CLEAR, 1);
}

fn vertex_buffer_format() u32 {
    return (@as(u32, @intCast(VERTEX_STRIDE)) << 16) |
        (@as(u32, @intCast(VERTEX_ATTR_COUNT)) << 28);
}

fn set_vsh_input_count_direct(count: c_int) void {
    const value = @as(u32, @intCast(count - 1));
    gpu_cmd_add_masked_write(c.GPUREG_VSH_INPUTBUFFER_CONFIG, 0xB, SH_MODE_VSH | value);
    gpu_cmd_add_write(c.GPUREG_VSH_NUM_ATTR, value);
}

fn gpu_cmd_add_write(reg: c_int, value: u32) void {
    gpu_cmd_add_masked_write(reg, 0xF, value);
}

fn gpu_cmd_add_masked_write(reg: c_int, mask: u32, value: u32) void {
    var param = value;
    c.GPUCMD_Add(gpu_cmd_header(false, mask, reg), &param, 1);
}

fn gpu_cmd_add_writes(reg: c_int, values: []const u32) void {
    c.GPUCMD_Add(gpu_cmd_header(false, 0xF, reg), values.ptr, @intCast(values.len));
}

fn gpu_cmd_add_incremental_writes(reg: c_int, values: []const u32) void {
    c.GPUCMD_Add(gpu_cmd_header(true, 0xF, reg), values.ptr, @intCast(values.len));
}

fn gpu_cmd_header(incremental: bool, mask: u32, reg: c_int) u32 {
    const inc: u32 = if (incremental) 1 else 0;
    return (inc << 31) | ((mask & 0xF) << 16) | (@as(u32, @intCast(reg)) & 0x3FF);
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
    upload_vec4(pl.u_pos_scale, POS_SCALE);
    upload_vec4(pl.u_uv_scale_offset, .{
        UV_SCALE[0],
        UV_SCALE[1],
        uv_offset[0],
        uv_offset[1],
    });
    upload_vec4(pl.u_color_scale, COLOR_SCALE);
}

fn upload_matrix(location: c_int, matrix: *const c.C3D_Mtx) void {
    const idx = uniform_location(location, 4) orelse return;
    const words: [*]const u32 = @ptrCast(matrix);
    gpu_cmd_add_write(c.GPUREG_VSH_FLOATUNIFORM_CONFIG, @as(u32, @intCast(idx)) | FLOAT_UNIFORM_UPLOAD_F32);
    gpu_cmd_add_writes(c.GPUREG_VSH_FLOATUNIFORM_DATA, words[0..16]);
}

fn upload_vec4(location: c_int, values: [4]f32) void {
    const idx = uniform_location(location, 1) orelse return;
    var vec: c.C3D_FVec = undefined;
    set_fvec(&vec, values[0], values[1], values[2], values[3]);
    const words: [*]const u32 = @ptrCast(&vec);
    gpu_cmd_add_write(c.GPUREG_VSH_FLOATUNIFORM_CONFIG, @as(u32, @intCast(idx)) | FLOAT_UNIFORM_UPLOAD_F32);
    gpu_cmd_add_writes(c.GPUREG_VSH_FLOATUNIFORM_DATA, words[0..4]);
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
    const upload = try ensure_texture_staging(tex, size / TEX_BPP);

    convert_texture_data(upload, data, tex.width, tex.height);
    flush_texture_source(upload);
    c.C3D_TexLoadImage(tex_ptr(tex), upload.ptr, c.GPU_TEXFACE_2D, 0);
    c.C3D_TexFlush(tex_ptr(tex));
}

fn ensure_texture_staging(tex: *TextureData, len: usize) ![]align(16) u32 {
    if (tex.staging) |buf| {
        if (buf.len >= len) return buf[0..len];
        render_alloc.free(buf);
        tex.staging = null;
    }

    const staging = try render_alloc.alignedAlloc(u32, .fromByteUnits(CACHE_LINE_SIZE), len);
    const bytes: [*]const u8 = @ptrCast(staging.ptr);
    if (!is_linear_fcram(bytes, len * TEX_BPP)) {
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

fn convert_texture_data(dst: []align(16) u32, src: []align(16) const u8, width: u32, height: u32) void {
    const factors = twiddle_factors(width, height);
    var y_bits: u32 = 0;
    for (0..height) |y| {
        const yu: u32 = @intCast(y);
        var x_bits: u32 = 0;
        for (0..width) |x| {
            const xu: u32 = @intCast(x);
            const src_off = (@as(usize, yu) * width + xu) * TEX_BPP;
            const dst_pixel = x_bits | (factors.mask_y - y_bits);
            dst[@intCast(dst_pixel)] =
                (@as(u32, src[src_off + 0]) << 24) |
                (@as(u32, src[src_off + 1]) << 16) |
                (@as(u32, src[src_off + 2]) << 8) |
                @as(u32, src[src_off + 3]);
            x_bits = (x_bits -% factors.mask_x) & factors.mask_x;
        }
        y_bits = (y_bits -% factors.mask_y) & factors.mask_y;
    }
}

const TwiddleFactors = struct {
    mask_x: u32,
    mask_y: u32,
};

fn twiddle_factors(width: u32, height: u32) TwiddleFactors {
    var mask_x: u32 = 0b010101;
    var mask_y: u32 = 0b101010;
    var w = width >> 4;
    var h = height >> 4;
    var shift: u5 = 6;

    while (w > 0) : (w >>= 1) {
        mask_x += @as(u32, 1) << shift;
        shift += 1;
    }
    while (h > 0) : (h >>= 1) {
        mask_y += @as(u32, 1) << shift;
        shift += 1;
    }

    return .{ .mask_x = mask_x, .mask_y = mask_y };
}

fn flush_texture_source(data: []align(16) u32) void {
    const bytes: [*]const u8 = @ptrCast(data.ptr);
    flush_data_cache(bytes, data.len * TEX_BPP);
}

fn texture_size(width: u32, height: u32) u32 {
    return @intCast(@as(usize, width) * height * TEX_BPP);
}

fn tex_ptr(tex: *TextureData) *c.C3D_Tex {
    return @ptrCast(&tex.tex);
}

fn flush_data_cache(ptr: [*]const u8, len: usize) void {
    if (len == 0) return;

    const start = @intFromPtr(ptr) & ~(CACHE_LINE_SIZE - 1);
    const end = std.mem.alignForward(usize, @intFromPtr(ptr) + len, CACHE_LINE_SIZE);
    const flush_ptr: *const anyopaque = @ptrFromInt(start);
    _ = c.GSPGPU_FlushDataCache(flush_ptr, @intCast(end - start));
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
