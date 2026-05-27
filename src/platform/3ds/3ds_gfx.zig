//! Minimal Nintendo 3DS Citro3D backend.
//!
//! First bring-up milestone: initialize the top-screen render target and draw
//! Aether's current colored triangle path. Textures and richer render state are
//! still no-ops until the next backend pass.

const std = @import("std");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;

const C3D_AttrInfo = opaque {};
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
extern fn C3D_GetTexEnv(id: c_int) *C3D_TexEnv;
extern fn C3D_DirtyTexEnv(env: *C3D_TexEnv) void;
extern fn C3D_CullFace(mode: c_int) void;
extern fn C3D_DepthTest(enable: bool, function: c_int, writemask: c_int) void;
extern fn C3D_AlphaBlend(colorEq: c_int, alphaEq: c_int, srcClr: c_int, dstClr: c_int, srcAlpha: c_int, dstAlpha: c_int) void;
extern fn C3D_ImmDrawBegin(primitive: c_int) void;
extern fn C3D_ImmSendAttrib(x: f32, y: f32, z: f32, w: f32) void;
extern fn C3D_ImmDrawEnd() void;
extern fn Mtx_OrthoTilt(mtx: *C3D_Mtx, left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32, isLeftHanded: bool) void;

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
const GPU_WRITE_COLOR = 0x0F;
const GPU_CULL_NONE = 0;
const GPU_BLEND_ADD = 0;
const GPU_ZERO = 0;
const GPU_ONE = 1;
const GPU_SRC_ALPHA = 6;
const GPU_ONE_MINUS_SRC_ALPHA = 7;
const GPU_PRIMARY_COLOR = 0x00;
const GPU_REPLACE = 0x00;
const GPU_TEVSCALE_1 = 0x0;
const GPU_TRIANGLES = 0x0000;

const GFX_TOP = 0;
const GFX_LEFT = 0;
const GX_TRANSFER_FMT_RGB8 = 1;
const DISPLAY_TRANSFER_FLAGS = GX_TRANSFER_FMT_RGB8 << 12;
const TOP_SCREEN_WIDTH: f32 = 400.0;
const TOP_SCREEN_HEIGHT: f32 = 240.0;

const ConvertedVertex = struct {
    pos: [4]f32,
    color: [4]f32,
};

const PipelineData = struct {
    program: ShaderProgram,
    dvlb: *DVLB,
    stride: usize,
    position_attr: Pipeline.Attribute,
    color_attr: ?Pipeline.Attribute,
    projection_loc: i8,
};

const MeshData = struct {
    pipeline: Pipeline.Handle,
    ptr: ?[*]ConvertedVertex = null,
    len: usize = 0,
    capacity: usize = 0,
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
var screen_projection: C3D_Mtx = undefined;

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var meshes = Util.CircularBuffer(MeshData, 2048).init();

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
    configure_color_texenv();
    C3D_CullFace(GPU_CULL_NONE);
    C3D_DepthTest(false, GPU_ALWAYS, GPU_WRITE_COLOR);
    set_alpha_blend(true);

    initialized = true;
}

pub fn deinit() void {
    destroy_all_meshes();
    destroy_all_pipelines();
    current_pipeline = 0;

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
    C3D_DepthTest(enabled, GPU_ALWAYS, if (enabled) GPU_WRITE_COLOR | 0x10 else GPU_WRITE_COLOR);
}

pub fn set_fog(_: bool, _: f32, _: f32, _: f32, _: f32, _: f32) void {}
pub fn set_clip_planes(_: bool) void {}
pub fn set_culling(enabled: bool) void {
    C3D_CullFace(if (enabled) 2 else GPU_CULL_NONE);
}
pub fn set_uv_offset(_: f32, _: f32) void {}

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
        .projection_loc = projection_loc,
    };

    const handle = pipelines.add_element(data) orelse return error.OutOfPipelines;
    return @intCast(handle);
}

pub fn destroy_pipeline(handle: Pipeline.Handle) void {
    var pl = pipelines.get_element(handle) orelse return;
    _ = shaderProgramFree(&pl.program);
    DVLB_Free(pl.dvlb);
    _ = pipelines.remove_element(handle);
    if (current_pipeline == handle) current_pipeline = 0;
}

pub fn bind_pipeline(handle: Pipeline.Handle) void {
    current_pipeline = handle;
}

pub fn create_mesh(pipeline: Pipeline.Handle) anyerror!Mesh.Handle {
    _ = pipelines.get_element(pipeline) orelse return error.InvalidPipeline;
    const handle = meshes.add_element(.{ .pipeline = pipeline }) orelse return error.OutOfMeshes;
    return @intCast(handle);
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    var mesh = meshes.get_element(handle) orelse return;
    free_mesh_vertices(&mesh);
    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    var mesh = meshes.get_element(handle) orelse return;
    const pl = pipelines.get_element(mesh.pipeline) orelse return;

    const vertex_count = if (pl.stride == 0) 0 else data.len / pl.stride;
    if (vertex_count > mesh.capacity) {
        free_mesh_vertices(&mesh);
        const verts = render_alloc.alloc(ConvertedVertex, vertex_count) catch {
            mesh.len = 0;
            mesh.capacity = 0;
            meshes.update_element(handle, mesh);
            return;
        };
        mesh.ptr = verts.ptr;
        mesh.capacity = verts.len;
    }

    if (mesh.ptr) |ptr| {
        const dst = ptr[0..mesh.capacity];
        for (0..vertex_count) |i| {
            const src = data[i * pl.stride ..][0..pl.stride];
            dst[i] = convert_vertex(src, pl);
        }
    }
    mesh.len = vertex_count;
    meshes.update_element(handle, mesh);
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize, primitive: Mesh.Primitive) void {
    if (!initialized or primitive != .triangles) return;

    const mesh = meshes.get_element(handle) orelse return;
    const ptr = mesh.ptr orelse return;
    const pipeline_handle = if (current_pipeline != 0) current_pipeline else mesh.pipeline;
    var pl = pipelines.get_element(pipeline_handle) orelse return;
    const draw_count = @min(count, mesh.len);
    if (draw_count == 0) return;

    const view_proj = Mat4.mul(current_view, current_proj);
    const mvp = Mat4.mul(model.*, view_proj);

    C3D_BindProgram(&pl.program);
    configure_fixed_attributes();
    upload_matrix_uniform(pl.projection_loc, &screen_projection);

    C3D_ImmDrawBegin(GPU_TRIANGLES);
    for (ptr[0..draw_count]) |vertex| {
        const pos = clip_to_screen(transform_pos(vertex.pos, &mvp));
        C3D_ImmSendAttrib(pos[0], pos[1], pos[2], pos[3]);
        C3D_ImmSendAttrib(vertex.color[0], vertex.color[1], vertex.color[2], vertex.color[3]);
    }
    C3D_ImmDrawEnd();
}

pub fn create_texture(_: u32, _: u32, _: []align(16) u8) anyerror!Texture.Handle {
    return 0;
}

pub fn update_texture(_: Texture.Handle, _: []align(16) u8) void {}
pub fn bind_texture(_: Texture.Handle) void {}
pub fn destroy_texture(_: Texture.Handle) void {}
pub fn force_texture_resident(_: Texture.Handle) void {}

fn render_target_clear(t: *C3D_RenderTarget, bits: c_int, color: u32, depth: u32) void {
    C3D_FrameBufClear(&t.frameBuf, bits, color, depth);
}

fn configure_fixed_attributes() void {
    const attr = C3D_GetAttrInfo();
    AttrInfo_Init(attr);
    _ = AttrInfo_AddLoader(attr, 0, GPU_FLOAT, 4);
    _ = AttrInfo_AddLoader(attr, 1, GPU_FLOAT, 4);
}

fn configure_color_texenv() void {
    const env = C3D_GetTexEnv(0);
    env.* = .{
        .srcRgb = GPU_PRIMARY_COLOR,
        .srcAlpha = GPU_PRIMARY_COLOR,
        .opAll = 0,
        .funcRgb = GPU_REPLACE,
        .funcAlpha = GPU_REPLACE,
        .color = 0xFFFFFFFF,
        .scaleRgb = GPU_TEVSCALE_1,
        .scaleAlpha = GPU_TEVSCALE_1,
    };
    C3D_DirtyTexEnv(env);
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

fn convert_vertex(src: []const u8, pl: PipelineData) ConvertedVertex {
    return .{
        .pos = decode_vec4(src, pl.position_attr, .{ 0.0, 0.0, 0.0, 1.0 }),
        .color = if (pl.color_attr) |attr| decode_color(src, attr) else .{ 1.0, 1.0, 1.0, 1.0 },
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
