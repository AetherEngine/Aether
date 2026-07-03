const std = @import("std");
const glfw = @import("glfw");
const gl = @import("gl");
const Mat4 = @import("../../../math/math.zig").Mat4;
const Util = @import("../../../util/util.zig");

const shader = @import("shader.zig");
const gfx = @import("../../gfx.zig");

const Rendering = @import("../../../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const vertex = Rendering.vertex;
const Texture = Rendering.Texture;
const GLFWSurface = @import("../surface.zig");
const basic_vert align(@alignOf(u32)) = @embedFile("aether_basic_vert").*;
const basic_frag align(@alignOf(u32)) = @embedFile("aether_basic_frag").*;

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

var procs: gl.ProcTable = undefined;
var last_width: u32 = 0;
var last_height: u32 = 0;
var meshes = Util.ResourceTable(MeshInternal, 8192, Mesh.Handle).init();
var textures = Util.ResourceTable(gl.uint, 8192, Texture.Handle).init();
var alpha_blend_enabled: bool = true;
var cull_face_enabled: bool = true;
var pipeline: PipelineData = undefined;
var pipeline_initialized: bool = false;

const PipelineData = struct {
    layout: vertex.VertexLayout,
    vao: gl.uint,
    program: shader.Shader,
};

const MeshInternal = struct {
    vbo: gl.uint,
    ebo: gl.uint,
    vertex_count: usize = 0,
    index_count: usize = 0,
};

pub fn init() anyerror!void {
    if (!procs.init(glfw.getProcAddress)) @panic("Failed to initialize OpenGL");
    gl.makeProcTableCurrent(&procs);

    Util.engine_logger.debug("OpenGL {s}", .{gl.GetString(gl.VERSION).?});
    Util.engine_logger.debug("GLSL {s}", .{gl.GetString(gl.SHADING_LANGUAGE_VERSION).?});
    Util.engine_logger.debug("Vendor: {s}", .{gl.GetString(gl.VENDOR).?});
    Util.engine_logger.debug("Renderer: {s}", .{gl.GetString(gl.RENDERER).?});

    gl.Viewport(0, 0, @intCast(gfx.surface.get_width()), @intCast(gfx.surface.get_height()));
    gl.ClipControl(gl.LOWER_LEFT, gl.ZERO_TO_ONE);
    gl.Enable(gl.DEPTH_TEST);
    gl.Enable(gl.CULL_FACE);
    gl.FrontFace(gl.CCW);
    gl.CullFace(gl.BACK);
    gl.Enable(gl.BLEND);
    gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
    gl.LineWidth(5.0);

    try shader.init();
    errdefer shader.deinit();

    shader.state.proj = Mat4.identity();
    shader.state.view = Mat4.identity();
    shader.update_ubo();

    pipeline = try init_pipeline(vertex.Layout);
    pipeline_initialized = true;
}

pub fn deinit() void {
    if (pipeline_initialized) {
        deinit_pipeline(&pipeline);
        pipeline_initialized = false;
    }
    shader.deinit();

    gl.makeProcTableCurrent(null);
    procs = undefined;
}

pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    gl.ClearColor(r, g, b, a);
}

pub fn set_alpha_blend(enabled: bool) void {
    const flag: u32 = @intFromBool(enabled);
    if (shader.state.alpha_blend_enabled != flag) {
        shader.state.alpha_blend_enabled = flag;
        shader.update_ubo();
    }
    if (enabled == alpha_blend_enabled) return;
    alpha_blend_enabled = enabled;
    if (enabled) gl.Enable(gl.BLEND) else gl.Disable(gl.BLEND);
}

pub fn set_depth_write(enabled: bool) void {
    gl.DepthMask(@intFromBool(enabled));
}

pub fn set_clip_planes(_: bool) void {}

pub fn set_culling(enabled: bool) void {
    if (enabled == cull_face_enabled) return;
    cull_face_enabled = enabled;
    if (enabled) gl.Enable(gl.CULL_FACE) else gl.Disable(gl.CULL_FACE);
}

pub fn set_uv_offset(u: f32, v: f32) void {
    if (shader.state.uv_offset[0] == u and shader.state.uv_offset[1] == v) return;
    shader.state.uv_offset = .{ u, v };
    shader.update_ubo();
}

pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    const fog_en: u32 = @intFromBool(enabled);
    if (shader.state.fog_enabled == fog_en and
        shader.state.fog_start == start and
        shader.state.fog_end == end and
        std.mem.eql(f32, &shader.state.fog_color, &.{ r, g, b })) return;
    shader.state.fog_enabled = fog_en;
    shader.state.fog_start = start;
    shader.state.fog_end = end;
    shader.state.fog_color = .{ r, g, b };
    shader.update_ubo();
}

pub fn start_frame() bool {
    const new_width = gfx.surface.get_width();
    const new_height = gfx.surface.get_height();
    if (new_width != last_width or new_height != last_height) {
        @branchHint(.unlikely);

        last_width = new_width;
        last_height = new_height;
        gl.Viewport(0, 0, @intCast(new_width), @intCast(new_height));

        if (new_width == 0 or new_height == 0) {
            return false;
        }
    }

    gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    return true;
}

pub fn end_frame() void {
    gfx.surface.draw();
}

pub fn clear_depth() void {
    gl.Clear(gl.DEPTH_BUFFER_BIT);
}

pub fn has_second_screen() bool {
    return false;
}

pub fn switch_second_screen() void {
    unreachable;
}

pub fn set_vsync(v: bool) void {
    glfw.swapInterval(@intFromBool(v));
}

pub fn set_proj_matrix(mat: *const Mat4) void {
    shader.state.proj = mat.*;
    shader.update_ubo();
}

pub fn set_view_matrix(mat: *const Mat4) void {
    shader.state.view = mat.*;
    shader.update_ubo();
}

fn init_pipeline(layout: vertex.VertexLayout) !PipelineData {
    var vao: gl.uint = 0;
    gl.CreateVertexArrays(1, @ptrCast(&vao));
    for (layout.attributes) |a| {
        gl.EnableVertexArrayAttrib(vao, a.location);

        gl.VertexArrayAttribFormat(vao, a.location, @intCast(a.size), switch (a.format) {
            .f32x2, .f32x3 => gl.FLOAT,
            .unorm8x2, .unorm8x4 => gl.UNSIGNED_BYTE,
            .unorm16x2, .unorm16x3 => gl.UNSIGNED_SHORT,
            .snorm16x2, .snorm16x3 => gl.SHORT,
        }, switch (a.format) {
            .f32x2, .f32x3 => gl.FALSE,
            .unorm8x2, .unorm8x4, .unorm16x2, .unorm16x3, .snorm16x2, .snorm16x3 => gl.TRUE,
        }, @intCast(a.offset));
        gl.VertexArrayAttribBinding(vao, a.location, a.binding);
    }

    const v_shader: [:0]align(4) const u8 = &basic_vert;
    const f_shader: [:0]align(4) const u8 = &basic_frag;
    const program = try shader.Shader.init(v_shader, f_shader);

    return .{
        .layout = layout,
        .vao = vao,
        .program = program,
    };
}

fn deinit_pipeline(pl: *PipelineData) void {
    gl.DeleteVertexArrays(1, @ptrCast(&pl.vao));
    pl.vao = 0;
    pl.program.deinit();
}

pub fn create_mesh() anyerror!Mesh.Handle {
    var vbo: gl.uint = 0;
    var ebo: gl.uint = 0;
    var buffers = [_]gl.uint{ 0, 0 };
    gl.CreateBuffers(2, @ptrCast(&buffers));
    vbo = buffers[0];
    ebo = buffers[1];
    gl.NamedBufferData(vbo, 0, null, gl.STATIC_DRAW);
    gl.NamedBufferData(ebo, 0, null, gl.STATIC_DRAW);

    const mesh_handle = meshes.add(.{
        .vbo = vbo,
        .ebo = ebo,
    }) orelse return error.OutOfMeshes;

    return mesh_handle;
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    var mesh = meshes.get(handle) orelse return;
    var buffers = [_]gl.uint{ mesh.vbo, mesh.ebo };
    gl.DeleteBuffers(2, @ptrCast(&buffers));
    mesh.vbo = 0;
    mesh.ebo = 0;

    _ = meshes.remove(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8, indices: []const Mesh.Index) void {
    var mesh = meshes.get(handle) orelse return;

    gl.NamedBufferData(mesh.vbo, @intCast(data.len), null, gl.STATIC_DRAW);
    gl.NamedBufferSubData(mesh.vbo, 0, @intCast(data.len), data.ptr);
    const index_bytes = std.mem.sliceAsBytes(indices);
    gl.NamedBufferData(mesh.ebo, @intCast(index_bytes.len), null, gl.STATIC_DRAW);
    if (index_bytes.len > 0) gl.NamedBufferSubData(mesh.ebo, 0, @intCast(index_bytes.len), index_bytes.ptr);

    mesh.vertex_count = data.len / vertex.Layout.stride;
    mesh.index_count = indices.len;
    _ = meshes.update(handle, mesh);
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4) void {
    if (!pipeline_initialized) return;
    const mesh = meshes.get(handle) orelse return;
    const pl = &pipeline;
    if (mesh.vertex_count == 0) return;

    shader.update_per_object(model);
    gl.BindVertexArray(pl.vao);
    gl.UseProgram(pl.program.shader_program);
    gl.VertexArrayVertexBuffer(pl.vao, 0, mesh.vbo, 0, @intCast(pl.layout.stride));
    if (mesh.index_count > 0) {
        gl.VertexArrayElementBuffer(pl.vao, mesh.ebo);
        gl.DrawElements(gl.TRIANGLES, @intCast(mesh.index_count), gl.UNSIGNED_SHORT, 0);
    } else {
        gl.DrawArrays(gl.TRIANGLES, 0, @intCast(mesh.vertex_count));
    }
}

pub fn create_texture(width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle {
    var tex: gl.uint = 0;
    gl.CreateTextures(gl.TEXTURE_2D, 1, @ptrCast(&tex));
    gl.TextureStorage2D(tex, 1, gl.RGBA8, @intCast(width), @intCast(height));
    gl.TextureSubImage2D(tex, 0, 0, 0, @intCast(width), @intCast(height), gl.RGBA, gl.UNSIGNED_BYTE, data.ptr);
    gl.TextureParameteri(tex, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
    gl.TextureParameteri(tex, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
    gl.TextureParameteri(tex, gl.TEXTURE_WRAP_S, gl.REPEAT);
    gl.TextureParameteri(tex, gl.TEXTURE_WRAP_T, gl.REPEAT);
    gl.GenerateTextureMipmap(tex);

    return textures.add(tex) orelse {
        gl.DeleteTextures(1, @ptrCast(&tex));
        return error.OutOfTextures;
    };
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const tex = textures.get(handle) orelse return;
    var w: gl.int = 0;
    var h: gl.int = 0;
    gl.GetTextureLevelParameteriv(tex, 0, gl.TEXTURE_WIDTH, @ptrCast(&w));
    gl.GetTextureLevelParameteriv(tex, 0, gl.TEXTURE_HEIGHT, @ptrCast(&h));
    gl.TextureSubImage2D(tex, 0, 0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, data.ptr);
}

pub fn bind_texture(handle: Texture.Handle) void {
    const tex = textures.get(handle) orelse return;
    gl.BindTextureUnit(2, tex);
}

pub fn destroy_texture(handle: Texture.Handle) void {
    var tex = textures.get(handle) orelse return;
    gl.DeleteTextures(1, @ptrCast(&tex));
    _ = textures.remove(handle);
}

pub fn force_texture_resident(_: Texture.Handle) void {}
