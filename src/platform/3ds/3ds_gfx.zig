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
const GPU_FLOAT = 3;
const GPU_RB_RGBA8 = 0;
const GPU_RB_DEPTH24_STENCIL8 = 3;
const GPU_ALWAYS = 1;
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
const GPU_REPEAT = 2;

const GFX_TOP = 0;
const GFX_LEFT = 0;
const GX_TRANSFER_FMT_RGB8 = 1;
const DISPLAY_TRANSFER_FLAGS = GX_TRANSFER_FMT_RGB8 << 12;
const TOP_SCREEN_WIDTH: f32 = 400.0;
const TOP_SCREEN_HEIGHT: f32 = 240.0;
const TEXTURE_BPP: usize = 4;
const MIN_TEXTURE_SIZE: u32 = 8;
const SMALL_TEXTURE_EXPAND_SIZE: u32 = 32;
const MAX_TEXTURE_SIZE: u32 = 1024;
const LINE_WIDTH: f32 = 1.5;
const DEBUG_UV_AS_COLOR = false;
const DEBUG_TEXTURE_ONLY = false;

const ConvertedVertex = struct {
    pos: [4]f32,
    color: [4]f32,
    uv: [2]f32,
};

const GpuVertex = extern struct {
    pos: [4]f32,
    uv: [2]f32,
    color: [4]f32,
};

const PipelineData = struct {
    program: ShaderProgram,
    dvlb: *DVLB,
    stride: usize,
    position_attr: Pipeline.Attribute,
    color_attr: ?Pipeline.Attribute,
    uv_attr: ?Pipeline.Attribute,
    projection_loc: i8,
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

var render_alloc: std.mem.Allocator = undefined;
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
var draw_vbo_raw: ?*anyopaque = null;
var draw_vbo: ?[*]GpuVertex = null;
var draw_vbo_capacity: usize = 0;

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var meshes = Util.CircularBuffer(MeshData, 2048).init();
var textures = Util.CircularBuffer(TextureData, 64).init();

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
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

    configure_fixed_attributes();
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
    free_draw_vbo();
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
    } else {
        C3D_AlphaBlend(GPU_BLEND_ADD, GPU_BLEND_ADD, GPU_ONE, GPU_ZERO, GPU_ONE, GPU_ZERO);
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

    const flags: u8 = if (vsync_enabled) C3D_FRAME_SYNCDRAW else 0;
    if (!C3D_FrameBegin(flags)) return false;

    render_target_clear(t, C3D_CLEAR_ALL, clear_color, 0);
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
    if (target) |t| render_target_clear(t, C3D_CLEAR_DEPTH, clear_color, 0);
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
    if (projection_loc < 0) return error.InvalidShader;

    const position_attr = find_attr(layout, .position) orelse return error.UnsupportedVertexLayout;
    const data = PipelineData{
        .program = program,
        .dvlb = dvlb,
        .stride = layout.stride,
        .position_attr = position_attr,
        .color_attr = find_attr(layout, .color),
        .uv_attr = find_attr(layout, .uv),
        .projection_loc = projection_loc,
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
        const bytes = render_alloc.alloc(u8, data.len) catch {
            mesh.len = 0;
            mesh.capacity = 0;
            return;
        };
        mesh.ptr = bytes.ptr;
        mesh.capacity = bytes.len;
    }

    if (mesh.ptr) |ptr| {
        @memcpy(ptr[0..data.len], data);
    }
    mesh.len = data.len;
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize, primitive: Mesh.Primitive) void {
    if (!initialized) return;

    const mesh = get_mesh_ptr(handle) orelse return;
    const ptr = mesh.ptr orelse return;
    const pipeline_handle = if (current_pipeline != 0) current_pipeline else mesh.pipeline;
    const pl = get_pipeline_ptr(pipeline_handle) orelse return;
    const available_count = if (pl.stride == 0) 0 else mesh.len / pl.stride;
    const draw_count = @min(count, available_count);
    if (draw_count == 0) return;

    const view_proj = Mat4.mul(current_view, current_proj);
    const mvp = Mat4.mul(model.*, view_proj);

    C3D_BindProgram(&pl.program);
    configure_fixed_attributes();
    configure_texture_texenv();
    bind_current_texture_for_draw();
    upload_matrix_uniform(pl.projection_loc, &screen_projection);

    const vbo_count = switch (primitive) {
        .triangles => draw_count,
        .lines => (draw_count / 2) * 6,
    };
    if (vbo_count == 0) return;
    const out = prepare_draw_vbo(vbo_count) orelse return;

    var written_count: usize = 0;
    switch (primitive) {
        .triangles => {
            for (0..draw_count) |i| {
                const vertex = decode_mesh_vertex(ptr, i, pl.*);
                out[i] = to_gpu_vertex(to_screen_vertex(vertex, &mvp));
            }
            written_count = draw_count;
        },
        .lines => {
            var src_i: usize = 0;
            var dst_i: usize = 0;
            while (src_i + 1 < draw_count) : (src_i += 2) {
                const a = decode_mesh_vertex(ptr, src_i, pl.*);
                const b = decode_mesh_vertex(ptr, src_i + 1, pl.*);
                dst_i = write_line_segment(out, dst_i, a, b, &mvp);
            }
            written_count = dst_i;
        },
    }
    if (written_count == 0) return;

    const draw_vertices = out[0..written_count];
    flush_draw_vbo(draw_vertices);
    configure_draw_buffer(out.ptr);
    C3D_DrawArrays(GPU_TRIANGLES, 0, @intCast(draw_vertices.len));
}

pub fn create_texture(width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle {
    const expand_small = width < MIN_TEXTURE_SIZE or height < MIN_TEXTURE_SIZE;
    const tex_width: u16 = if (expand_small) @intCast(SMALL_TEXTURE_EXPAND_SIZE) else try texture_dim(width);
    const tex_height: u16 = if (expand_small) @intCast(SMALL_TEXTURE_EXPAND_SIZE) else try texture_dim(height);
    const upload_len = @as(usize, tex_width) * @as(usize, tex_height) * TEXTURE_BPP;
    const upload_data = try render_alloc.alignedAlloc(u8, .fromByteUnits(16), upload_len);
    errdefer render_alloc.free(upload_data);

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
    render_alloc.free(tex.upload_data);
    _ = textures.remove_element(handle);
    if (bound_texture == handle) bound_texture = 0;
}

pub fn force_texture_resident(_: Texture.Handle) void {}

fn render_target_clear(t: *C3D_RenderTarget, bits: c_int, color: u32, depth: u32) void {
    C3D_FrameBufClear(&t.frameBuf, bits, color, depth);
}

fn apply_depth_state() void {
    const depth_mask: c_int = if (depth_write_enabled) GPU_WRITE_DEPTH else 0;
    const mask: c_int = GPU_WRITE_COLOR | depth_mask;
    C3D_DepthTest(true, GPU_GEQUAL, mask);
}

fn configure_fixed_attributes() void {
    const attr = C3D_GetAttrInfo();
    AttrInfo_Init(attr);
    _ = AttrInfo_AddLoader(attr, 0, GPU_FLOAT, 4);
    _ = AttrInfo_AddLoader(attr, 1, GPU_FLOAT, 2);
    _ = AttrInfo_AddLoader(attr, 2, GPU_FLOAT, 4);
}

fn configure_draw_buffer(ptr: [*]GpuVertex) void {
    const buf = C3D_GetBufInfo();
    BufInfo_Init(buf);
    _ = BufInfo_Add(buf, @ptrCast(&ptr[0]), @intCast(@sizeOf(GpuVertex)), 3, 0x210);
}

fn configure_texture_texenv() void {
    const env = C3D_GetTexEnv(0);
    const src = if (DEBUG_UV_AS_COLOR)
        tev_sources(GPU_PRIMARY_COLOR, GPU_PRIMARY_COLOR, GPU_PRIMARY_COLOR)
    else if (DEBUG_TEXTURE_ONLY)
        tev_sources(GPU_TEXTURE0, GPU_TEXTURE0, GPU_TEXTURE0)
    else
        tev_sources(GPU_TEXTURE0, GPU_PRIMARY_COLOR, GPU_PRIMARY_COLOR);
    const func = if (DEBUG_UV_AS_COLOR or DEBUG_TEXTURE_ONLY) GPU_REPLACE else GPU_MODULATE;

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

fn upload_matrix_uniform(loc: i8, mat: *const C3D_Mtx) void {
    if (loc < 0) return;

    const base: usize = @intCast(loc);
    if (base + 4 > C3D_FVUNIF_COUNT) return;

    inline for (0..4) |i| {
        C3D_FVUnif[GPU_VERTEX_SHADER][base + i] = mat.r[i];
        C3D_FVUnifDirty[GPU_VERTEX_SHADER][base + i] = true;
    }
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
            render_alloc.free(tex.upload_data);
            slot.* = null;
        }
    }
    textures.clear();
}

fn prepare_draw_vbo(count: usize) ?[]GpuVertex {
    if (count > draw_vbo_capacity) {
        free_draw_vbo();

        const bytes = count * @sizeOf(GpuVertex);
        const mem = linearAlloc(bytes) orelse return null;
        const aligned: *align(@alignOf(GpuVertex)) anyopaque = @alignCast(mem);
        const ptr: [*]GpuVertex = @ptrCast(aligned);
        draw_vbo_raw = mem;
        draw_vbo = ptr;
        draw_vbo_capacity = count;
    }

    const ptr = draw_vbo orelse return null;
    return ptr[0..count];
}

fn flush_draw_vbo(vertices: []GpuVertex) void {
    _ = GSPGPU_FlushDataCache(@ptrCast(&vertices[0]), @intCast(vertices.len * @sizeOf(GpuVertex)));
}

fn free_draw_vbo() void {
    if (draw_vbo_raw) |mem| {
        linearFree(mem);
    }
    draw_vbo_raw = null;
    draw_vbo = null;
    draw_vbo_capacity = 0;
}

fn free_mesh_vertices(mesh: *MeshData) void {
    if (mesh.ptr) |ptr| {
        render_alloc.free(ptr[0..mesh.capacity]);
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

fn decode_mesh_vertex(ptr: [*]const u8, index: usize, pl: PipelineData) ConvertedVertex {
    const src = ptr[index * pl.stride ..][0..pl.stride];
    return convert_vertex(src, pl);
}

fn convert_vertex(src: []const u8, pl: PipelineData) ConvertedVertex {
    return .{
        .pos = decode_vec4(src, pl.position_attr, .{ 0.0, 0.0, 0.0, 1.0 }),
        .color = if (pl.color_attr) |attr| decode_color(src, attr) else .{ 1.0, 1.0, 1.0, 1.0 },
        .uv = if (pl.uv_attr) |attr| decode_vec2(src, attr, .{ 0.0, 0.0 }) else .{ 0.0, 0.0 },
    };
}

fn decode_vec2(src: []const u8, attr: Pipeline.Attribute, default: [2]f32) [2]f32 {
    const off = attr.offset;
    return switch (attr.format) {
        .f32x2, .f32x3 => .{ read_f32(src, off, default[0]), read_f32(src, off + 4, default[1]) },
        .unorm8x2, .unorm8x4 => .{ read_u8_norm(src, off, default[0]), read_u8_norm(src, off + 1, default[1]) },
        .unorm16x2, .unorm16x3 => .{ read_u16_norm(src, off, default[0]), read_u16_norm(src, off + 2, default[1]) },
        .snorm16x2, .snorm16x3 => .{ read_i16_norm(src, off, default[0]), read_i16_norm(src, off + 2, default[1]) },
    };
}

fn decode_vec4(src: []const u8, attr: Pipeline.Attribute, default: [4]f32) [4]f32 {
    const off = attr.offset;
    return switch (attr.format) {
        .f32x2 => .{ read_f32(src, off, default[0]), read_f32(src, off + 4, default[1]), default[2], default[3] },
        .f32x3 => .{ read_f32(src, off, default[0]), read_f32(src, off + 4, default[1]), read_f32(src, off + 8, default[2]), default[3] },
        .unorm8x2 => .{ read_u8_norm(src, off, default[0]), read_u8_norm(src, off + 1, default[1]), default[2], default[3] },
        .unorm8x4 => .{ read_u8_norm(src, off, default[0]), read_u8_norm(src, off + 1, default[1]), read_u8_norm(src, off + 2, default[2]), read_u8_norm(src, off + 3, default[3]) },
        .unorm16x2 => .{ read_u16_norm(src, off, default[0]), read_u16_norm(src, off + 2, default[1]), default[2], default[3] },
        .unorm16x3 => .{ read_u16_norm(src, off, default[0]), read_u16_norm(src, off + 2, default[1]), read_u16_norm(src, off + 4, default[2]), default[3] },
        .snorm16x2 => .{ read_i16_norm(src, off, default[0]), read_i16_norm(src, off + 2, default[1]), default[2], default[3] },
        .snorm16x3 => .{ read_i16_norm(src, off, default[0]), read_i16_norm(src, off + 2, default[1]), read_i16_norm(src, off + 4, default[2]), default[3] },
    };
}

fn decode_color(src: []const u8, attr: Pipeline.Attribute) [4]f32 {
    return switch (attr.format) {
        .unorm8x4 => decode_vec4(src, attr, .{ 1.0, 1.0, 1.0, 1.0 }),
        .f32x3 => .{
            read_f32(src, attr.offset, 1.0),
            read_f32(src, attr.offset + 4, 1.0),
            read_f32(src, attr.offset + 8, 1.0),
            1.0,
        },
        .f32x2, .unorm8x2, .unorm16x2, .unorm16x3, .snorm16x2, .snorm16x3 => decode_vec4(src, attr, .{ 1.0, 1.0, 1.0, 1.0 }),
    };
}

const ScreenVertex = struct {
    pos: [4]f32,
    color: [4]f32,
    uv: [2]f32,
};

fn to_screen_vertex(vertex: ConvertedVertex, mvp: *const Mat4) ScreenVertex {
    return .{
        .pos = clip_to_screen(transform_pos(vertex.pos, mvp)),
        .color = vertex.color,
        .uv = transform_uv(vertex.uv),
    };
}

fn transform_uv(uv: [2]f32) [2]f32 {
    const texture_scale = if (get_texture_ptr(bound_texture)) |tex| tex.uv_scale else .{ 1.0, 1.0 };
    return .{
        (uv[0] + uv_offset[0]) * texture_scale[0],
        (uv[1] + uv_offset[1]) * texture_scale[1],
    };
}

fn to_gpu_vertex(vertex: ScreenVertex) GpuVertex {
    return .{
        .pos = vertex.pos,
        .uv = vertex.uv,
        .color = vertex.color,
    };
}

fn write_line_segment(dst: []GpuVertex, index: usize, a: ConvertedVertex, b: ConvertedVertex, mvp: *const Mat4) usize {
    const av = to_screen_vertex(a, mvp);
    const bv = to_screen_vertex(b, mvp);
    const dx = bv.pos[0] - av.pos[0];
    const dy = bv.pos[1] - av.pos[1];
    const len_sq = dx * dx + dy * dy;
    if (len_sq <= 0.000001) return index;

    const inv_len = 1.0 / @sqrt(len_sq);
    const nx = -dy * inv_len * (LINE_WIDTH * 0.5);
    const ny = dx * inv_len * (LINE_WIDTH * 0.5);

    const a0 = offset_screen_vertex(av, nx, ny);
    const a1 = offset_screen_vertex(av, -nx, -ny);
    const b0 = offset_screen_vertex(bv, nx, ny);
    const b1 = offset_screen_vertex(bv, -nx, -ny);

    dst[index + 0] = to_gpu_vertex(a0);
    dst[index + 1] = to_gpu_vertex(a1);
    dst[index + 2] = to_gpu_vertex(b0);
    dst[index + 3] = to_gpu_vertex(b0);
    dst[index + 4] = to_gpu_vertex(a1);
    dst[index + 5] = to_gpu_vertex(b1);
    return index + 6;
}

fn offset_screen_vertex(vertex: ScreenVertex, dx: f32, dy: f32) ScreenVertex {
    var out = vertex;
    out.pos[0] += dx;
    out.pos[1] += dy;
    return out;
}

fn transform_pos(pos: [4]f32, mat: *const Mat4) [4]f32 {
    return .{
        pos[0] * mat.data[0][0] + pos[1] * mat.data[1][0] + pos[2] * mat.data[2][0] + pos[3] * mat.data[3][0],
        pos[0] * mat.data[0][1] + pos[1] * mat.data[1][1] + pos[2] * mat.data[2][1] + pos[3] * mat.data[3][1],
        pos[0] * mat.data[0][2] + pos[1] * mat.data[1][2] + pos[2] * mat.data[2][2] + pos[3] * mat.data[3][2],
        pos[0] * mat.data[0][3] + pos[1] * mat.data[1][3] + pos[2] * mat.data[2][3] + pos[3] * mat.data[3][3],
    };
}

fn clip_to_screen(pos: [4]f32) [4]f32 {
    const inv_w: f32 = if (@abs(pos[3]) > 0.000001) 1.0 / pos[3] else 1.0;
    const ndc_x = pos[0] * inv_w;
    const ndc_y = pos[1] * inv_w;
    const ndc_z = pos[2] * inv_w;

    return .{
        (ndc_x * 0.5 + 0.5) * TOP_SCREEN_WIDTH,
        (ndc_y * 0.5 + 0.5) * TOP_SCREEN_HEIGHT,
        @max(0.0, @min(1.0, ndc_z)),
        1.0,
    };
}

fn init_white_texture() !void {
    if (white_texture_ready) return;

    var data align(16) = [_]u8{0xFF} ** (MIN_TEXTURE_SIZE * MIN_TEXTURE_SIZE * TEXTURE_BPP);
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
    _ = GSPGPU_FlushDataCache(data.ptr, @intCast(data.len));
    C3D_TexLoadImage(tex, data.ptr, GPU_TEXFACE_2D, 0);
}

fn tex_set_default_params(tex: *C3D_Tex) void {
    tex.param &= ~(gpu_texture_mag_filter(GPU_LINEAR) | gpu_texture_min_filter(GPU_LINEAR));
    tex.param |= gpu_texture_mag_filter(GPU_NEAREST) | gpu_texture_min_filter(GPU_NEAREST);
    tex.param &= ~(gpu_texture_wrap_s(3) | gpu_texture_wrap_t(3));
    tex.param |= gpu_texture_wrap_s(GPU_REPEAT) | gpu_texture_wrap_t(GPU_REPEAT);
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

fn convert_texture_data(dst: []align(16) u8, src: []const u8, width: u32, height: u32, tex_width: u16, tex_height: u16, expand_small: bool) void {
    const source_len = @as(usize, width) * @as(usize, height) * TEXTURE_BPP;
    if (src.len < source_len) return;

    const tw: u32 = tex_width;
    const th: u32 = tex_height;
    for (0..th) |y| {
        const sy = if (expand_small)
            @min((@as(u32, @intCast(y)) * height) / th, height - 1)
        else
            @min(@as(u32, @intCast(y)), height - 1);
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

fn read_f32(src: []const u8, offset: usize, default: f32) f32 {
    if (offset + 4 > src.len) return default;
    const bits = std.mem.readInt(u32, src[offset..][0..4], .little);
    return @bitCast(bits);
}

fn read_u8_norm(src: []const u8, offset: usize, default: f32) f32 {
    if (offset >= src.len) return default;
    return @as(f32, @floatFromInt(src[offset])) / 255.0;
}

fn read_u16_norm(src: []const u8, offset: usize, default: f32) f32 {
    if (offset + 2 > src.len) return default;
    const value = std.mem.readInt(u16, src[offset..][0..2], .little);
    return @as(f32, @floatFromInt(value)) / 65535.0;
}

fn read_i16_norm(src: []const u8, offset: usize, default: f32) f32 {
    if (offset + 2 > src.len) return default;
    const bits = std.mem.readInt(u16, src[offset..][0..2], .little);
    const value: i16 = @bitCast(bits);
    return @max(-1.0, @as(f32, @floatFromInt(value)) / 32767.0);
}

fn floatByte(v: f32) u8 {
    return @intFromFloat(@max(0.0, @min(1.0, v)) * 255.0);
}
