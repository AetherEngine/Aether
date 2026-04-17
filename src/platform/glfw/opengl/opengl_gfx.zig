const std = @import("std");
const Util = @import("../../../util/util.zig");
const glfw = @import("glfw");
const gl = @import("gl");
const Mat4 = @import("../../../math/math.zig").Mat4;

const shader = @import("shader.zig");
const gfx = @import("../../gfx.zig");

const Rendering = @import("../../../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Pipeline = Rendering.Pipeline;
const Texture = Rendering.Texture;
const GLFWSurface = @import("../surface.zig");

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

var procs: gl.ProcTable = undefined;
var last_width: u32 = 0;
var last_height: u32 = 0;
var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var meshes = Util.CircularBuffer(MeshInternal, 8192).init();
var alpha_blend_enabled: bool = true;

const PipelineData = struct {
    layout: Pipeline.VertexLayout,
    vao: gl.uint,
    program: shader.Shader,
};

const MeshInternal = struct {
    pipeline: Pipeline.Handle,
    vbo: gl.uint,
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
    shader.state.proj = Mat4.identity();
    shader.state.view = Mat4.identity();
    shader.update_ubo();

}

pub fn deinit() void {

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

pub fn create_pipeline(layout: Pipeline.VertexLayout, v_shader: ?[:0]align(4) const u8, f_shader: ?[:0]align(4) const u8) anyerror!Pipeline.Handle {
    if (v_shader == null or f_shader == null) {
        return error.InvalidShader;
    }

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

    const program = try shader.Shader.init(v_shader.?, f_shader.?);

    const pipeline = pipelines.add_element(.{
        .layout = layout,
        .vao = vao,
        .program = program,
    }) orelse return error.OutOfPipelines;

    return @intCast(pipeline);
}

pub fn bind_pipeline(pipeline: Pipeline.Handle) void {
    const pl = pipelines.get_element(pipeline) orelse return;
    gl.BindVertexArray(pl.vao);
    gl.UseProgram(pl.program.shader_program);
}

pub fn destroy_pipeline(pipeline: Pipeline.Handle) void {
    var pl = pipelines.get_element(pipeline) orelse return;
    gl.DeleteVertexArrays(1, @ptrCast(&pl.vao));
    pl.vao = 0;
    pl.program.deinit();

    _ = pipelines.remove_element(pipeline);
}

pub fn create_mesh(pipeline: Pipeline.Handle) anyerror!Mesh.Handle {
    const pl = pipelines.get_element(pipeline).?;
    var vbo: gl.uint = 0;
    gl.CreateBuffers(1, @ptrCast(&vbo));
    gl.NamedBufferData(vbo, 0, null, gl.STATIC_DRAW);
    gl.VertexArrayVertexBuffer(pl.vao, 0, vbo, 0, @intCast(pl.layout.stride));

    const mesh_idx = meshes.add_element(.{
        .pipeline = pipeline,
        .vbo = vbo,
    }) orelse return error.OutOfMeshes;

    return @intCast(mesh_idx);
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    var mesh = meshes.get_element(handle) orelse return;
    gl.DeleteBuffers(1, @ptrCast(&mesh.vbo));
    mesh.vbo = 0;

    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    const mesh = meshes.get_element(handle) orelse return;

    gl.NamedBufferData(mesh.vbo, @intCast(data.len), null, gl.STATIC_DRAW);
    gl.NamedBufferSubData(mesh.vbo, 0, @intCast(data.len), data.ptr);
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize, primitive: Mesh.Primitive) void {
    const mesh = meshes.get_element(handle) orelse return;
    const pl = pipelines.get_element(mesh.pipeline) orelse return;

    shader.update_per_object(model);
    gl.VertexArrayVertexBuffer(pl.vao, 0, mesh.vbo, 0, @intCast(pl.layout.stride));
    gl.DrawArrays(switch (primitive) {
        .triangles => gl.TRIANGLES,
        .lines => gl.LINES,
    }, 0, @intCast(count));
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

    return tex;
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    var w: gl.int = 0;
    var h: gl.int = 0;
    gl.GetTextureLevelParameteriv(handle, 0, gl.TEXTURE_WIDTH, @ptrCast(&w));
    gl.GetTextureLevelParameteriv(handle, 0, gl.TEXTURE_HEIGHT, @ptrCast(&h));
    gl.TextureSubImage2D(handle, 0, 0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, data.ptr);
}

pub fn bind_texture(handle: Texture.Handle) void {
    gl.BindTextureUnit(2, handle);
}

pub fn destroy_texture(handle: Texture.Handle) void {
    gl.DeleteTextures(1, @ptrCast(&handle));
}

pub fn force_texture_resident(_: Texture.Handle) void {}
