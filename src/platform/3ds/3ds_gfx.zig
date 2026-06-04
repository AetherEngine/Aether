//! Nintendo 3DS Citro3D backend.
//!
//! The top screen render target is physically 240x400 and displayed rotated.
//! This backend keeps Aether's normal landscape projection contract by
//! transforming vertices to top-screen coordinates on the CPU, then using
//! Citro3D's tilted orthographic projection for the final hardware transform.

const std = @import("std");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;

const C3D_AttrInfo = opaque {};
const C3D_BufInfo = opaque {};
const C3D_RenderTarget = extern struct {
    next: ?*C3D_RenderTarget,
    prev: ?*C3D_RenderTarget,
    frameBuf: C3D_FrameBuf,
    used: bool,
    ownsColor: bool,
    ownsDepth: bool,
    linked: bool,
    screen: c_int,
    side: c_int,
    transferFlags: u32,
};
const C3D_FrameBuf = extern struct {
    colorBuf: ?*anyopaque,
    depthBuf: ?*anyopaque,
    width: u16,
    height: u16,
    colorFmt: c_int,
    depthFmt: c_int,
    block32: bool,
    masks: u8,
};
const C3D_TexEnv = extern struct {
    srcRgb: u16,
    srcAlpha: u16,
    opAll: u32,
    funcRgb: u16,
    funcAlpha: u16,
    color: u32,
    scaleRgb: u16,
    scaleAlpha: u16,
};
const C3D_FVec = extern struct {
    w: f32,
    z: f32,
    y: f32,
    x: f32,
};
const C3D_Mtx = extern struct {
    r: [4]C3D_FVec,
};
const C3D_Tex = extern struct {
    data: ?*anyopaque,
    fmt_size: u32,
    dim: u32,
    param: u32,
    border: u32,
    lod_param: u32,
};
const C3D_FogLut = extern struct {
    data: [128]u32,
};

const DVLP = extern struct {
    codeSize: u32,
    codeData: [*]u32,
    opdescSize: u32,
    opcdescData: [*]u32,
};
const DVLEConstEntry = extern struct {
    typ: u16,
    id: u16,
    data: [4]u32,
};
const DVLEOutEntry = extern struct {
    typ: u16,
    regID: u16,
    mask: u8,
    unk: [3]u8,
};
const DVLEUniformEntry = extern struct {
    symbolOffset: u32,
    startReg: u16,
    endReg: u16,
};
const DVLE = extern struct {
    typ: c_int,
    mergeOutmaps: bool,
    gshMode: c_int,
    gshFixedVtxStart: u8,
    gshVariableVtxNum: u8,
    gshFixedVtxNum: u8,
    dvlp: *DVLP,
    mainOffset: u32,
    endmainOffset: u32,
    constTableSize: u32,
    constTableData: [*]DVLEConstEntry,
    outTableSize: u32,
    outTableData: [*]DVLEOutEntry,
    uniformTableSize: u32,
    uniformTableData: [*]DVLEUniformEntry,
    symbolTableData: [*]u8,
    outmapMask: u8,
    outmapData: [8]u32,
    outmapMode: u32,
    outmapClock: u32,
};
const DVLB = extern struct {
    numDVLE: u32,
    DVLP: DVLP,
    DVLE: [*]DVLE,
};
const ShaderInstance = opaque {};
const ShaderProgram = extern struct {
    vertexShader: ?*ShaderInstance,
    geometryShader: ?*ShaderInstance,
    geoShaderInputPermutation: [2]u32,
    geoShaderInputStride: u8,
};

extern fn gfxInitDefault() void;
extern fn gfxExit() void;

extern fn C3D_Init(cmdBufSize: usize) bool;
extern fn C3D_Fini() void;
extern fn C3D_FrameBegin(flags: u8) bool;
extern fn C3D_FrameDrawOn(target: *C3D_RenderTarget) bool;
extern fn C3D_FrameEnd(flags: u8) void;
extern fn C3D_RenderTargetCreate(width: c_int, height: c_int, colorFmt: c_int, depthFmt: c_int) ?*C3D_RenderTarget;
extern fn C3D_RenderTargetDelete(target: *C3D_RenderTarget) void;
extern fn C3D_RenderTargetSetOutput(target: ?*C3D_RenderTarget, screen: c_int, side: c_int, transferFlags: u32) void;
extern fn C3D_FrameBufClear(fb: *C3D_FrameBuf, clearBits: c_int, clearColor: u32, clearDepth: u32) void;
extern fn C3D_BindProgram(program: *ShaderProgram) void;
extern fn C3D_GetAttrInfo() *C3D_AttrInfo;
extern fn AttrInfo_Init(info: *C3D_AttrInfo) void;
extern fn AttrInfo_AddLoader(info: *C3D_AttrInfo, regId: c_int, format: c_int, count: c_int) c_int;
extern fn C3D_GetBufInfo() *C3D_BufInfo;
extern fn BufInfo_Init(info: *C3D_BufInfo) void;
extern fn BufInfo_Add(info: *C3D_BufInfo, data: ?*const anyopaque, stride: isize, attribCount: c_int, permutation: u64) c_int;
extern fn C3D_GetTexEnv(id: c_int) *C3D_TexEnv;
extern fn C3D_DirtyTexEnv(env: *C3D_TexEnv) void;
extern fn C3D_CullFace(mode: c_int) void;
extern fn C3D_DepthTest(enable: bool, function: c_int, writemask: c_int) void;
extern fn C3D_AlphaTest(enable: bool, function: c_int, ref: c_int) void;
extern fn C3D_AlphaBlend(colorEq: c_int, alphaEq: c_int, srcClr: c_int, dstClr: c_int, srcAlpha: c_int, dstAlpha: c_int) void;
extern fn C3D_DrawArrays(primitive: c_int, first: c_int, size: c_int) void;
extern fn C3D_TexInitWithParams(tex: *C3D_Tex, cube: ?*anyopaque, params: u64) bool;
extern fn C3D_TexLoadImage(tex: *C3D_Tex, data: ?*const anyopaque, face: c_int, level: c_int) void;
extern fn C3D_TexBind(unitId: c_int, tex: *C3D_Tex) void;
extern fn C3D_TexDelete(tex: *C3D_Tex) void;
extern fn C3D_FogGasMode(fogMode: c_int, gasMode: c_int, zFlip: bool) void;
extern fn C3D_FogColor(color: u32) void;
extern fn C3D_FogLutBind(lut: *C3D_FogLut) void;
extern fn FogLut_FromArray(lut: *C3D_FogLut, data: *const [256]f32) void;
extern fn GSPGPU_FlushDataCache(adr: ?*const anyopaque, size: u32) c_int;
extern fn Mtx_OrthoTilt(mtx: *C3D_Mtx, left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32, isLeftHanded: bool) void;
extern fn linearAlloc(size: usize) ?*anyopaque;
extern fn linearFree(mem: ?*anyopaque) void;

extern fn DVLB_ParseFile(shbinData: [*]u32, shbinSize: u32) ?*DVLB;
extern fn DVLB_Free(dvlb: *DVLB) void;
extern fn shaderProgramInit(sp: *ShaderProgram) c_int;
extern fn shaderProgramFree(sp: *ShaderProgram) c_int;
extern fn shaderProgramSetVsh(sp: *ShaderProgram, dvle: *DVLE) c_int;
extern fn shaderInstanceGetUniformLocation(si: *ShaderInstance, name: [*:0]const u8) i8;

extern var C3D_FVUnif: [2][C3D_FVUNIF_COUNT]C3D_FVec;
extern var C3D_FVUnifDirty: [2][C3D_FVUNIF_COUNT]bool;

const C3D_DEFAULT_CMDBUF_SIZE = 0x40000;
const C3D_FRAME_SYNCDRAW = 1 << 0;
const C3D_CLEAR_COLOR = 1 << 0;
const C3D_CLEAR_DEPTH = 1 << 1;
const C3D_CLEAR_ALL = C3D_CLEAR_COLOR | C3D_CLEAR_DEPTH;
const C3D_FVUNIF_COUNT = 96;

const GPU_VERTEX_SHADER = 0;
const GPU_BYTE = 0;
const GPU_UNSIGNED_BYTE = 1;
const GPU_SHORT = 2;
const GPU_FLOAT = 3;
const GPU_RB_RGBA8 = 0;
const GPU_RB_DEPTH24_STENCIL8 = 3;
const GPU_ALWAYS = 1;
const GPU_GREATER = 6;
const GPU_GEQUAL = 7;
const GPU_WRITE_COLOR = 0x0F;
const GPU_WRITE_DEPTH = 0x10;
const GPU_CULL_NONE = 0;
const GPU_CULL_BACK_CCW = 2;
const GPU_BLEND_ADD = 0;
const GPU_ZERO = 0;
const GPU_ONE = 1;
const GPU_SRC_ALPHA = 6;
const GPU_ONE_MINUS_SRC_ALPHA = 7;
const GPU_PRIMARY_COLOR = 0x00;
const GPU_TEXTURE0 = 0x03;
const GPU_PREVIOUS = 0x0F;
const GPU_REPLACE = 0x00;
const GPU_MODULATE = 0x01;
const GPU_TEVSCALE_1 = 0x0;
const GPU_TRIANGLES = 0x0000;
const GPU_NO_FOG = 0;
const GPU_FOG = 5;
const GPU_PLAIN_DENSITY = 0;
const GPU_TEX_2D = 0;
const GPU_TEXFACE_2D = 0;
const GPU_RGBA8 = 0;
const GPU_NEAREST = 0;
const GPU_LINEAR = 1;
const GPU_CLAMP_TO_EDGE = 0;
const GPU_REPEAT = 2;

const GFX_TOP = 0;
const GFX_LEFT = 0;
const GX_TRANSFER_FMT_RGB8 = 1;
const DISPLAY_TRANSFER_FLAGS = GX_TRANSFER_FMT_RGB8 << 12;
const TOP_SCREEN_WIDTH: f32 = 400.0;
const TOP_SCREEN_HEIGHT: f32 = 240.0;
const TEXTURE_BPP: usize = 4;
const DATA_CACHE_LINE_SIZE: usize = 32;
const DEPTH_CLEAR: u32 = 0;
const ALPHA_REF: c_int = 26;
const LINEAR_MESH_MIN_CAPACITY: usize = 256;
const MIN_TEXTURE_SIZE: u32 = 8;
const SMALL_TEXTURE_EXPAND_SIZE: u32 = 32;
const MAX_TEXTURE_SIZE: u32 = 1024;
const DEBUG_TEXTURE_ONLY = false;
const DEBUG_COLOR_ONLY = false;
const DEBUG_DRAW_QUAD_CHUNKS = false;

const PipelineData = struct {
    program: ShaderProgram,
    dvlb: *DVLB,
    stride: usize,
    position_attr: Pipeline.Attribute,
    uv_attr: Pipeline.Attribute,
    color_attr: Pipeline.Attribute,
    position_loader_size: u8,
    uv_loader_size: u8,
    color_loader_size: u8,
    buffer_base_offset: usize,
    buffer_attribute_count: u8,
    buffer_permutation: u64,
    projection_loc: i8,
    model_view_loc: i8,
    screen_projection_loc: i8,
    pos_scale_loc: i8,
    uv_scale_offset_loc: i8,
    color_scale_loc: i8,
    pos_scale: [3]f32,
    uv_attr_scale: [2]f32,
    color_scale: [4]f32,
};

const MeshData = struct {
    pipeline: Pipeline.Handle,
    ptr: ?[*]u8 = null,
    len: usize = 0,
    capacity: usize = 0,
};

const TextureData = struct {
    width: u32,
    height: u32,
    tex_width: u16,
    tex_height: u16,
    uv_scale: [2]f32,
    upload_data: []align(16) u8,
    tex: C3D_Tex,
};

var render_io: std.Io = undefined;

var initialized: bool = false;
var target: ?*C3D_RenderTarget = null;
var clear_color: u32 = 0x000000FF;
var vsync_enabled: bool = true;
var current_pipeline: Pipeline.Handle = 0;
var current_proj: Mat4 = Mat4.identity();
var current_view: Mat4 = Mat4.identity();
var uv_offset: [2]f32 = .{ 0.0, 0.0 };
var depth_write_enabled: bool = true;
var screen_projection: C3D_Mtx = undefined;
var fog_lut: C3D_FogLut = undefined;
var white_texture: C3D_Tex = undefined;
var white_texture_ready: bool = false;
var bound_texture: Texture.Handle = 0;

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var meshes = Util.CircularBuffer(MeshData, 2048).init();
var textures = Util.CircularBuffer(TextureData, 64).init();

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    _ = alloc;
    render_io = io;
}

pub fn init() anyerror!void {
    _ = render_io;

    gfxInitDefault();
    errdefer gfxExit();

    if (!C3D_Init(C3D_DEFAULT_CMDBUF_SIZE)) return error.GfxInitFailed;
    errdefer C3D_Fini();

    target = C3D_RenderTargetCreate(240, 400, GPU_RB_RGBA8, GPU_RB_DEPTH24_STENCIL8);
    if (target == null) return error.GfxInitFailed;
    errdefer {
        C3D_RenderTargetDelete(target.?);
        target = null;
    }

    C3D_RenderTargetSetOutput(target, GFX_TOP, GFX_LEFT, DISPLAY_TRANSFER_FLAGS);
    Mtx_OrthoTilt(&screen_projection, 0.0, TOP_SCREEN_WIDTH, 0.0, TOP_SCREEN_HEIGHT, 0.0, 1.0, true);

    configure_texture_texenv();
    try init_white_texture();
    C3D_CullFace(GPU_CULL_NONE);
    apply_depth_state();
    C3D_FogGasMode(GPU_NO_FOG, GPU_PLAIN_DENSITY, false);
    set_alpha_blend(true);

    initialized = true;
}

pub fn deinit() void {
    destroy_all_meshes();
    destroy_all_pipelines();
    destroy_all_textures();
    current_pipeline = 0;
    bound_texture = 0;

    if (white_texture_ready) {
        C3D_TexDelete(&white_texture);
        white_texture_ready = false;
    }

    if (target) |t| {
        C3D_RenderTargetDelete(t);
        target = null;
    }

    if (initialized) {
        C3D_Fini();
        gfxExit();
        initialized = false;
    }
}

pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    clear_color = (@as(u32, floatByte(r)) << 24) |
        (@as(u32, floatByte(g)) << 16) |
        (@as(u32, floatByte(b)) << 8) |
        @as(u32, floatByte(a));
}

pub fn set_alpha_blend(enabled: bool) void {
    if (enabled) {
        C3D_AlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD, GPU_SRC_ALPHA, GPU_ONE_MINUS_SRC_ALPHA, GPU_SRC_ALPHA, GPU_ONE_MINUS_SRC_ALPHA);
        C3D_AlphaTest(false, GPU_ALWAYS, 0);
    } else {
        C3D_AlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD, GPU_ONE, GPU_ZERO, GPU_ONE, GPU_ZERO);
        C3D_AlphaTest(false, GPU_ALWAYS, 0);
    }
}

pub fn set_depth_write(enabled: bool) void {
    depth_write_enabled = enabled;
    apply_depth_state();
}

pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    if (!enabled or end <= start) {
        C3D_FogGasMode(GPU_NO_FOG, GPU_PLAIN_DENSITY, false);
        return;
    }

    var data: [256]f32 = undefined;
    for (&data, 0..) |*v, i| {
        const z = @as(f32, @floatFromInt(i)) / 255.0;
        v.* = @max(0.0, @min(1.0, (z - start) / (end - start)));
    }

    FogLut_FromArray(&fog_lut, &data);
    C3D_FogColor((@as(u32, floatByte(r)) << 16) |
        (@as(u32, floatByte(g)) << 8) |
        @as(u32, floatByte(b)));
    C3D_FogGasMode(GPU_FOG, GPU_PLAIN_DENSITY, false);
    C3D_FogLutBind(&fog_lut);
}

pub fn set_clip_planes(_: bool) void {}

pub fn set_culling(enabled: bool) void {
    C3D_CullFace(if (enabled) GPU_CULL_BACK_CCW else GPU_CULL_NONE);
}

pub fn set_uv_offset(u: f32, v: f32) void {
    uv_offset = .{ u, v };
}

pub fn set_proj_matrix(mat: *const Mat4) void {
    current_proj = mat.*;
}

pub fn set_view_matrix(mat: *const Mat4) void {
    current_view = mat.*;
}

pub fn start_frame() bool {
    const t = target orelse return false;
    if (!initialized) return false;

    _ = vsync_enabled;
    if (!C3D_FrameBegin(C3D_FRAME_SYNCDRAW)) return false;

    render_target_clear(t, C3D_CLEAR_ALL, clear_color, DEPTH_CLEAR);
    if (!C3D_FrameDrawOn(t)) {
        C3D_FrameEnd(0);
        return false;
    }

    return true;
}

pub fn end_frame() void {
    if (!initialized) return;
    C3D_FrameEnd(0);
}

pub fn clear_depth() void {
    if (target) |t| render_target_clear(t, C3D_CLEAR_DEPTH, clear_color, DEPTH_CLEAR);
}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
}

pub fn create_pipeline(layout: Pipeline.VertexLayout, v_shader: ?[:0]align(4) const u8, _: ?[:0]align(4) const u8) anyerror!Pipeline.Handle {
    const code = v_shader orelse return error.InvalidShader;
    if (code.len == 0) return error.InvalidShader;

    const dvlb = DVLB_ParseFile(@ptrCast(@constCast(code.ptr)), @intCast(code.len)) orelse return error.InvalidShader;
    errdefer DVLB_Free(dvlb);
    if (dvlb.numDVLE == 0) return error.InvalidShader;

    var program: ShaderProgram = undefined;
    if (shaderProgramInit(&program) != 0) return error.InvalidShader;
    errdefer _ = shaderProgramFree(&program);
    if (shaderProgramSetVsh(&program, &dvlb.DVLE[0]) != 0) return error.InvalidShader;

    const vertex_shader = program.vertexShader orelse return error.InvalidShader;
    const projection_loc = shaderInstanceGetUniformLocation(vertex_shader, "projection");
    const model_view_loc = shaderInstanceGetUniformLocation(vertex_shader, "modelView");
    const screen_projection_loc = shaderInstanceGetUniformLocation(vertex_shader, "screenProjection");
    const pos_scale_loc = shaderInstanceGetUniformLocation(vertex_shader, "posScale");
    const uv_scale_offset_loc = shaderInstanceGetUniformLocation(vertex_shader, "uvScaleOffset");
    const color_scale_loc = shaderInstanceGetUniformLocation(vertex_shader, "colorScale");
    if (projection_loc < 0 or
        model_view_loc < 0 or
        screen_projection_loc < 0 or
        pos_scale_loc < 0 or
        uv_scale_offset_loc < 0 or
        color_scale_loc < 0)
    {
        return error.InvalidShader;
    }

    const position_attr = find_attr(layout, .position) orelse return error.UnsupportedVertexLayout;
    const uv_attr = find_attr(layout, .uv) orelse return error.UnsupportedVertexLayout;
    const color_attr = find_attr(layout, .color) orelse return error.UnsupportedVertexLayout;
    const pos_scale = position_scale(position_attr) orelse return error.UnsupportedVertexLayout;
    const uv_attr_scale = uv_scale(uv_attr) orelse return error.UnsupportedVertexLayout;
    const color_attr_scale = color_scale(color_attr) orelse return error.UnsupportedVertexLayout;
    const buffer_layout = buffer_layout_from_attrs(layout.stride, position_attr, uv_attr, color_attr) orelse return error.UnsupportedVertexLayout;
    const data = PipelineData{
        .program = program,
        .dvlb = dvlb,
        .stride = layout.stride,
        .position_attr = position_attr,
        .uv_attr = uv_attr,
        .color_attr = color_attr,
        .position_loader_size = buffer_layout.position_loader_size,
        .uv_loader_size = buffer_layout.uv_loader_size,
        .color_loader_size = buffer_layout.color_loader_size,
        .buffer_base_offset = buffer_layout.base_offset,
        .buffer_attribute_count = buffer_layout.attribute_count,
        .buffer_permutation = buffer_layout.permutation,
        .projection_loc = projection_loc,
        .model_view_loc = model_view_loc,
        .screen_projection_loc = screen_projection_loc,
        .pos_scale_loc = pos_scale_loc,
        .uv_scale_offset_loc = uv_scale_offset_loc,
        .color_scale_loc = color_scale_loc,
        .pos_scale = pos_scale,
        .uv_attr_scale = uv_attr_scale,
        .color_scale = color_attr_scale,
    };

    const handle = pipelines.add_element(data) orelse return error.OutOfPipelines;
    return @intCast(handle);
}

pub fn destroy_pipeline(handle: Pipeline.Handle) void {
    const pl = get_pipeline_ptr(handle) orelse return;
    _ = shaderProgramFree(&pl.program);
    DVLB_Free(pl.dvlb);
    _ = pipelines.remove_element(handle);
    if (current_pipeline == handle) current_pipeline = 0;
}

pub fn bind_pipeline(handle: Pipeline.Handle) void {
    current_pipeline = handle;
}

pub fn create_mesh(pipeline: Pipeline.Handle) anyerror!Mesh.Handle {
    _ = get_pipeline_ptr(pipeline) orelse return error.InvalidPipeline;
    const handle = meshes.add_element(.{ .pipeline = pipeline }) orelse return error.OutOfMeshes;
    return @intCast(handle);
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    const mesh = get_mesh_ptr(handle) orelse return;
    free_mesh_vertices(mesh);
    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    const mesh = get_mesh_ptr(handle) orelse return;

    if (data.len > mesh.capacity) {
        free_mesh_vertices(mesh);
        const new_capacity = linear_mesh_capacity(data.len);
        const bytes = alloc_linear_bytes(new_capacity) catch {
            mesh.len = 0;
            mesh.capacity = 0;
            return;
        };
        mesh.ptr = bytes.ptr;
        mesh.capacity = bytes.len;
    }

    if (mesh.ptr) |ptr| {
        @memcpy(ptr[0..data.len], data);
        flush_data_cache_range(@ptrCast(&ptr[0]), data.len);
    }
    mesh.len = data.len;
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize, primitive: Mesh.Primitive) void {
    if (!initialized) return;
    if (primitive == .lines) return;

    const mesh = get_mesh_ptr(handle) orelse return;
    const ptr = mesh.ptr orelse return;
    const pipeline_handle = if (current_pipeline != 0) current_pipeline else mesh.pipeline;
    const pl = get_pipeline_ptr(pipeline_handle) orelse return;
    const available_count = if (pl.stride == 0) 0 else mesh.len / pl.stride;
    const draw_count = @min(count, available_count);
    if (draw_count == 0) return;

    const model_view = Mat4.mul(model.*, current_view);

    C3D_BindProgram(&pl.program);
    configure_fixed_attributes(pl.*);
    configure_texture_texenv();
    bind_current_texture_for_draw();
    apply_depth_state();
    upload_aether_matrix_uniform(pl.projection_loc, &current_proj);
    upload_aether_matrix_uniform(pl.model_view_loc, &model_view);
    upload_c3d_matrix_uniform(pl.screen_projection_loc, &screen_projection);
    upload_vec_uniform(pl.pos_scale_loc, .{ pl.pos_scale[0], pl.pos_scale[1], pl.pos_scale[2], 1.0 });
    upload_uv_uniform(pl.*);
    upload_vec_uniform(pl.color_scale_loc, pl.color_scale);

    if (!configure_draw_buffer(ptr, pl.*)) return;
    if (DEBUG_DRAW_QUAD_CHUNKS) {
        var first: usize = 0;
        while (first < draw_count) : (first += 6) {
            const chunk_count = @min(@as(usize, 6), draw_count - first);
            C3D_DrawArrays(GPU_TRIANGLES, @intCast(first), @intCast(chunk_count));
        }
    } else {
        C3D_DrawArrays(GPU_TRIANGLES, 0, @intCast(draw_count));
    }
}

pub fn create_texture(width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle {
    const expand_small = width < MIN_TEXTURE_SIZE or height < MIN_TEXTURE_SIZE;
    const tex_width: u16 = if (expand_small) @intCast(SMALL_TEXTURE_EXPAND_SIZE) else try texture_dim(width);
    const tex_height: u16 = if (expand_small) @intCast(SMALL_TEXTURE_EXPAND_SIZE) else try texture_dim(height);
    const upload_len = @as(usize, tex_width) * @as(usize, tex_height) * TEXTURE_BPP;
    const upload_data = try alloc_linear_bytes(upload_len);
    errdefer free_linear_bytes(upload_data);

    var tex: C3D_Tex = undefined;
    if (!tex_init(&tex, tex_width, tex_height, false)) return error.TextureCreateFailed;
    errdefer C3D_TexDelete(&tex);
    tex_set_default_params(&tex);

    convert_texture_data(upload_data, data, width, height, tex_width, tex_height, expand_small);
    tex_upload(&tex, upload_data);

    const handle = textures.add_element(.{
        .width = width,
        .height = height,
        .tex_width = tex_width,
        .tex_height = tex_height,
        .uv_scale = if (expand_small) .{ 1.0, 1.0 } else .{
            @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(tex_width)),
            @as(f32, @floatFromInt(height)) / @as(f32, @floatFromInt(tex_height)),
        },
        .upload_data = upload_data,
        .tex = tex,
    }) orelse return error.OutOfTextures;

    return @intCast(handle);
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const tex = get_texture_ptr(handle) orelse return;
    const expand_small = tex.width < MIN_TEXTURE_SIZE or tex.height < MIN_TEXTURE_SIZE;
    convert_texture_data(tex.upload_data, data, tex.width, tex.height, tex.tex_width, tex.tex_height, expand_small);
    tex_upload(&tex.tex, tex.upload_data);
}

pub fn bind_texture(handle: Texture.Handle) void {
    bound_texture = if (get_texture_ptr(handle) != null) handle else 0;
}

pub fn destroy_texture(handle: Texture.Handle) void {
    const tex = get_texture_ptr(handle) orelse return;
    C3D_TexDelete(&tex.tex);
    free_linear_bytes(tex.upload_data);
    _ = textures.remove_element(handle);
    if (bound_texture == handle) bound_texture = 0;
}

pub fn force_texture_resident(_: Texture.Handle) void {}

fn render_target_clear(t: *C3D_RenderTarget, bits: c_int, color: u32, depth: u32) void {
    C3D_FrameBufClear(&t.frameBuf, bits, color, depth);
}

fn apply_depth_state() void {
    _ = depth_write_enabled;
    C3D_DepthTest(false, GPU_ALWAYS, GPU_WRITE_COLOR);
}

fn configure_fixed_attributes(pl: PipelineData) void {
    const attr = C3D_GetAttrInfo();
    AttrInfo_Init(attr);
    add_attr_loader(attr, 0, pl.position_attr, pl.position_loader_size);
    add_attr_loader(attr, 1, pl.uv_attr, pl.uv_loader_size);
    add_attr_loader(attr, 2, pl.color_attr, pl.color_loader_size);
}

fn add_attr_loader(info: *C3D_AttrInfo, reg_id: c_int, attr: Pipeline.Attribute, loader_size: u8) void {
    const fmt = gpu_attribute_format(attr.format);
    _ = AttrInfo_AddLoader(info, reg_id, fmt, loader_size);
}

fn configure_draw_buffer(ptr: [*]u8, pl: PipelineData) bool {
    const buf = C3D_GetBufInfo();
    BufInfo_Init(buf);
    const result = BufInfo_Add(
        buf,
        @ptrCast(&ptr[pl.buffer_base_offset]),
        @intCast(pl.stride),
        @intCast(pl.buffer_attribute_count),
        pl.buffer_permutation,
    );
    if (result < 0) {
        BufInfo_Init(buf);
        return false;
    }
    return true;
}

fn configure_texture_texenv() void {
    const env = C3D_GetTexEnv(0);
    const src = if (DEBUG_COLOR_ONLY)
        tev_sources(GPU_PRIMARY_COLOR, GPU_PRIMARY_COLOR, GPU_PRIMARY_COLOR)
    else if (DEBUG_TEXTURE_ONLY)
        tev_sources(GPU_TEXTURE0, GPU_TEXTURE0, GPU_TEXTURE0)
    else
        tev_sources(GPU_TEXTURE0, GPU_PRIMARY_COLOR, GPU_PRIMARY_COLOR);
    const func = if (DEBUG_COLOR_ONLY or DEBUG_TEXTURE_ONLY) GPU_REPLACE else GPU_MODULATE;

    env.* = .{
        .srcRgb = src,
        .srcAlpha = src,
        .opAll = 0,
        .funcRgb = func,
        .funcAlpha = func,
        .color = 0xFFFFFFFF,
        .scaleRgb = GPU_TEVSCALE_1,
        .scaleAlpha = GPU_TEVSCALE_1,
    };
    C3D_DirtyTexEnv(env);

    var stage: c_int = 1;
    while (stage < 6) : (stage += 1) {
        configure_passthrough_texenv(stage);
    }
}

fn configure_passthrough_texenv(stage: c_int) void {
    const env = C3D_GetTexEnv(stage);
    env.* = .{
        .srcRgb = tev_sources(GPU_PREVIOUS, 0, 0),
        .srcAlpha = tev_sources(GPU_PREVIOUS, 0, 0),
        .opAll = 0,
        .funcRgb = GPU_REPLACE,
        .funcAlpha = GPU_REPLACE,
        .color = 0xFFFFFFFF,
        .scaleRgb = GPU_TEVSCALE_1,
        .scaleAlpha = GPU_TEVSCALE_1,
    };
    C3D_DirtyTexEnv(env);
}

fn tev_sources(a: u16, b: u16, c: u16) u16 {
    return a | (b << 4) | (c << 8);
}

fn bind_current_texture_for_draw() void {
    if (get_texture_ptr(bound_texture)) |tex| {
        C3D_TexBind(0, &tex.tex);
        return;
    }

    if (white_texture_ready) {
        C3D_TexBind(0, &white_texture);
    }
}

fn upload_aether_matrix_uniform(loc: i8, mat: *const Mat4) void {
    const c3d = mat4_to_c3d(mat);
    upload_c3d_matrix_uniform(loc, &c3d);
}

fn upload_c3d_matrix_uniform(loc: i8, mat: *const C3D_Mtx) void {
    if (loc < 0) return;

    const base: usize = @intCast(loc);
    if (base + 4 > C3D_FVUNIF_COUNT) return;

    inline for (0..4) |i| {
        C3D_FVUnif[GPU_VERTEX_SHADER][base + i] = mat.r[i];
        C3D_FVUnifDirty[GPU_VERTEX_SHADER][base + i] = true;
    }
}

fn upload_vec_uniform(loc: i8, v: [4]f32) void {
    if (loc < 0) return;

    const base: usize = @intCast(loc);
    if (base >= C3D_FVUNIF_COUNT) return;

    C3D_FVUnif[GPU_VERTEX_SHADER][base] = fvec(v[0], v[1], v[2], v[3]);
    C3D_FVUnifDirty[GPU_VERTEX_SHADER][base] = true;
}

fn upload_uv_uniform(pl: PipelineData) void {
    const texture_scale = if (get_texture_ptr(bound_texture)) |tex| tex.uv_scale else .{ 1.0, 1.0 };
    upload_vec_uniform(pl.uv_scale_offset_loc, .{
        pl.uv_attr_scale[0] * texture_scale[0],
        pl.uv_attr_scale[1] * texture_scale[1],
        uv_offset[0] * texture_scale[0],
        uv_offset[1] * texture_scale[1],
    });
}

fn mat4_to_c3d(mat: *const Mat4) C3D_Mtx {
    return .{ .r = .{
        fvec(mat.data[0][0], mat.data[1][0], mat.data[2][0], mat.data[3][0]),
        fvec(mat.data[0][1], mat.data[1][1], mat.data[2][1], mat.data[3][1]),
        fvec(mat.data[0][2], mat.data[1][2], mat.data[2][2], mat.data[3][2]),
        fvec(mat.data[0][3], mat.data[1][3], mat.data[2][3], mat.data[3][3]),
    } };
}

fn fvec(x: f32, y: f32, z: f32, w: f32) C3D_FVec {
    return .{ .x = x, .y = y, .z = z, .w = w };
}

fn destroy_all_pipelines() void {
    for (&pipelines.buffer) |*slot| {
        if (slot.*) |*pl| {
            _ = shaderProgramFree(&pl.program);
            DVLB_Free(pl.dvlb);
            slot.* = null;
        }
    }
    pipelines.clear();
}

fn destroy_all_meshes() void {
    for (&meshes.buffer) |*slot| {
        if (slot.*) |*mesh| {
            free_mesh_vertices(mesh);
            slot.* = null;
        }
    }
    meshes.clear();
}

fn destroy_all_textures() void {
    for (&textures.buffer) |*slot| {
        if (slot.*) |*tex| {
            C3D_TexDelete(&tex.tex);
            free_linear_bytes(tex.upload_data);
            slot.* = null;
        }
    }
    textures.clear();
}

fn free_mesh_vertices(mesh: *MeshData) void {
    if (mesh.ptr) |ptr| {
        linearFree(ptr);
        mesh.ptr = null;
    }
    mesh.len = 0;
    mesh.capacity = 0;
}

fn find_attr(layout: Pipeline.VertexLayout, usage: Pipeline.AttributeUsage) ?Pipeline.Attribute {
    for (layout.attributes) |attr| {
        if (attr.usage == usage) return attr;
    }
    return null;
}

const BufferLayout = struct {
    base_offset: usize,
    attribute_count: u8,
    permutation: u64,
    position_loader_size: u8,
    uv_loader_size: u8,
    color_loader_size: u8,
};

fn buffer_layout_from_attrs(stride: usize, position_attr: Pipeline.Attribute, uv_attr: Pipeline.Attribute, color_attr: Pipeline.Attribute) ?BufferLayout {
    var attrs = [_]Pipeline.Attribute{ position_attr, uv_attr, color_attr };
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
        const loader_size = attribute_loader_size(attr, next_offset - attr.offset) orelse return null;
        const loaded_bytes = attribute_size_bytes_with_count(attr.format, loader_size) orelse return null;
        if (loaded_bytes > next_offset - attr.offset) return null;
        if (i + 1 < attrs.len and loaded_bytes != next_offset - attr.offset) return null;
        const shift: u6 = @intCast(attribute_count * 4);
        permutation |= attribute_loader_id(attr.usage) << shift;
        attribute_count += 1;
        switch (attr.usage) {
            .position => position_loader_size = loader_size,
            .uv => uv_loader_size = loader_size,
            .color => color_loader_size = loader_size,
            .normal => unreachable,
        }
        current_rel = rel_offset + loaded_bytes;
    }

    if (stride < current_rel) return null;
    if (position_loader_size == 0 or uv_loader_size == 0 or color_loader_size == 0) return null;

    return .{
        .base_offset = base_offset,
        .attribute_count = @intCast(attribute_count),
        .permutation = permutation,
        .position_loader_size = position_loader_size,
        .uv_loader_size = uv_loader_size,
        .color_loader_size = color_loader_size,
    };
}

fn sort_attrs_by_offset(attrs: *[3]Pipeline.Attribute) void {
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

fn attribute_loader_id(usage: Pipeline.AttributeUsage) u64 {
    return switch (usage) {
        .position => 0,
        .uv => 1,
        .color => 2,
        .normal => unreachable,
    };
}

fn attr_fits(stride: usize, attr: Pipeline.Attribute) bool {
    const size = attribute_size_bytes(attr.format);
    return attr.offset <= stride and size <= stride - attr.offset;
}

fn attribute_loader_size(attr: Pipeline.Attribute, available_bytes: usize) ?u8 {
    if (attr.usage == .position and attr.size == 3 and attribute_component_size_bytes(attr.format) == 2 and available_bytes >= 8) {
        return 4;
    }
    if (attr.size > 4) return null;
    return @intCast(attr.size);
}

fn attribute_size_bytes(format: Pipeline.AttributeFormat) usize {
    return switch (format) {
        .f32x2 => 8,
        .f32x3 => 12,
        .unorm8x2 => 2,
        .unorm8x4 => 4,
        .unorm16x2, .snorm16x2 => 4,
        .unorm16x3, .snorm16x3 => 6,
    };
}

fn attribute_size_bytes_with_count(format: Pipeline.AttributeFormat, count: u8) ?usize {
    if (count == 0 or count > 4) return null;
    return attribute_component_size_bytes(format) * @as(usize, count);
}

fn attribute_component_size_bytes(format: Pipeline.AttributeFormat) usize {
    return switch (format) {
        .f32x2, .f32x3 => 4,
        .unorm8x2, .unorm8x4 => 1,
        .unorm16x2, .unorm16x3, .snorm16x2, .snorm16x3 => 2,
    };
}

fn gpu_attribute_format(format: Pipeline.AttributeFormat) c_int {
    return switch (format) {
        .f32x2, .f32x3 => GPU_FLOAT,
        .unorm8x2, .unorm8x4 => GPU_UNSIGNED_BYTE,
        .unorm16x2, .unorm16x3, .snorm16x2, .snorm16x3 => GPU_SHORT,
    };
}

fn position_scale(attr: Pipeline.Attribute) ?[3]f32 {
    if (attr.size != 3) return null;
    return switch (attr.format) {
        .f32x3 => .{ 1.0, 1.0, 1.0 },
        .snorm16x3 => .{ snorm16_scale(), snorm16_scale(), snorm16_scale() },
        else => null,
    };
}

fn uv_scale(attr: Pipeline.Attribute) ?[2]f32 {
    if (attr.size != 2) return null;
    return switch (attr.format) {
        .f32x2 => .{ 1.0, 1.0 },
        .unorm8x2 => .{ unorm8_scale(), unorm8_scale() },
        .snorm16x2 => .{ snorm16_scale(), snorm16_scale() },
        else => null,
    };
}

fn color_scale(attr: Pipeline.Attribute) ?[4]f32 {
    if (attr.size != 4) return null;
    return switch (attr.format) {
        .unorm8x4 => .{ unorm8_scale(), unorm8_scale(), unorm8_scale(), unorm8_scale() },
        else => null,
    };
}

fn snorm16_scale() f32 {
    return 1.0 / 32767.0;
}

fn unorm8_scale() f32 {
    return 1.0 / 255.0;
}

fn linear_mesh_capacity(required: usize) usize {
    var capacity: usize = LINEAR_MESH_MIN_CAPACITY;
    while (capacity < required) : (capacity *= 2) {}
    return capacity;
}

fn init_white_texture() !void {
    if (white_texture_ready) return;

    const data = try alloc_linear_bytes(MIN_TEXTURE_SIZE * MIN_TEXTURE_SIZE * TEXTURE_BPP);
    defer free_linear_bytes(data);
    @memset(data, 0xFF);

    if (!tex_init(&white_texture, MIN_TEXTURE_SIZE, MIN_TEXTURE_SIZE, false)) {
        return error.TextureCreateFailed;
    }
    errdefer C3D_TexDelete(&white_texture);

    tex_set_default_params(&white_texture);
    tex_upload(&white_texture, data[0..]);
    white_texture_ready = true;
}

fn tex_init(tex: *C3D_Tex, width: u16, height: u16, vram: bool) bool {
    return C3D_TexInitWithParams(tex, null, tex_init_params(width, height, 0, GPU_RGBA8, GPU_TEX_2D, vram));
}

fn tex_upload(tex: *C3D_Tex, data: []align(16) const u8) void {
    flush_data_cache_range(data.ptr, data.len);
    C3D_TexLoadImage(tex, data.ptr, GPU_TEXFACE_2D, 0);
}

fn flush_data_cache_range(ptr: *const anyopaque, len: usize) void {
    if (len == 0) return;

    const start = @intFromPtr(ptr);
    const aligned_start = std.mem.alignBackward(usize, start, DATA_CACHE_LINE_SIZE);
    const aligned_end = std.mem.alignForward(usize, start + len, DATA_CACHE_LINE_SIZE);
    const aligned_len = aligned_end - aligned_start;
    const aligned_ptr: *const anyopaque = @ptrFromInt(aligned_start);
    _ = GSPGPU_FlushDataCache(aligned_ptr, @intCast(aligned_len));
}

fn tex_set_default_params(tex: *C3D_Tex) void {
    tex.param &= ~(gpu_texture_mag_filter(GPU_LINEAR) | gpu_texture_min_filter(GPU_LINEAR));
    tex.param |= gpu_texture_mag_filter(GPU_NEAREST) | gpu_texture_min_filter(GPU_NEAREST);
    tex.param &= ~(gpu_texture_wrap_s(3) | gpu_texture_wrap_t(3));
    tex.param |= gpu_texture_wrap_s(GPU_CLAMP_TO_EDGE) | gpu_texture_wrap_t(GPU_CLAMP_TO_EDGE);
}

fn tex_init_params(width: u16, height: u16, max_level: u8, format: u8, tex_type: u8, vram: bool) u64 {
    const flags0: u8 = (max_level & 0x0F) | ((format & 0x0F) << 4);
    const flags1: u8 = (tex_type & 0x07) | (@as(u8, @intFromBool(vram)) << 3);
    return @as(u64, width) |
        (@as(u64, height) << 16) |
        (@as(u64, flags0) << 32) |
        (@as(u64, flags1) << 40);
}

fn gpu_texture_mag_filter(v: u32) u32 {
    return (v & 0x1) << 1;
}

fn gpu_texture_min_filter(v: u32) u32 {
    return (v & 0x1) << 2;
}

fn gpu_texture_wrap_s(v: u32) u32 {
    return (v & 0x3) << 12;
}

fn gpu_texture_wrap_t(v: u32) u32 {
    return (v & 0x3) << 8;
}

fn get_texture_ptr(handle: Texture.Handle) ?*TextureData {
    if (handle == 0 or handle >= textures.buffer.len) return null;
    if (textures.buffer[handle]) |*tex| return tex;
    return null;
}

fn get_pipeline_ptr(handle: Pipeline.Handle) ?*PipelineData {
    if (handle == 0 or handle >= pipelines.buffer.len) return null;
    if (pipelines.buffer[handle]) |*pl| return pl;
    return null;
}

fn get_mesh_ptr(handle: Mesh.Handle) ?*MeshData {
    if (handle == 0 or handle >= meshes.buffer.len) return null;
    if (meshes.buffer[handle]) |*mesh| return mesh;
    return null;
}

fn texture_dim(value: u32) !u16 {
    if (value == 0 or value > MAX_TEXTURE_SIZE) return error.InvalidTextureSize;

    var out: u32 = MIN_TEXTURE_SIZE;
    while (out < value) : (out <<= 1) {}
    if (out > MAX_TEXTURE_SIZE) return error.InvalidTextureSize;
    return @intCast(out);
}

fn alloc_linear_bytes(len: usize) ![]align(16) u8 {
    const mem = linearAlloc(len) orelse return error.OutOfMemory;
    const aligned: *align(16) anyopaque = @alignCast(mem);
    const ptr: [*]align(16) u8 = @ptrCast(aligned);
    return ptr[0..len];
}

fn free_linear_bytes(bytes: []align(16) u8) void {
    linearFree(bytes.ptr);
}

fn convert_texture_data(dst: []align(16) u8, src: []const u8, width: u32, height: u32, tex_width: u16, tex_height: u16, expand_small: bool) void {
    const source_len = @as(usize, width) * @as(usize, height) * TEXTURE_BPP;
    if (src.len < source_len) return;

    const tw: u32 = tex_width;
    const th: u32 = tex_height;
    for (0..th) |y| {
        const source_y = if (expand_small)
            @min((@as(u32, @intCast(y)) * height) / th, height - 1)
        else
            @min(@as(u32, @intCast(y)), height - 1);
        const sy = height - 1 - source_y;
        for (0..tw) |x| {
            const sx = if (expand_small)
                @min((@as(u32, @intCast(x)) * width) / tw, width - 1)
            else
                @min(@as(u32, @intCast(x)), width - 1);
            const src_off = (@as(usize, sy) * width + sx) * TEXTURE_BPP;
            const dst_off = tiled_pixel_offset(@intCast(x), @intCast(y), tw) * TEXTURE_BPP;
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

fn floatByte(v: f32) u8 {
    return @intFromFloat(@max(0.0, @min(1.0, v)) * 255.0);
}
