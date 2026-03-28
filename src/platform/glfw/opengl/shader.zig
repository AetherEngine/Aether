const std = @import("std");
const gl = @import("gl");
const Mat4 = @import("../../../math/math.zig").Mat4;
const assert = std.debug.assert;
const Util = @import("../../../util/util.zig");

pub const ShaderState = struct {
    view: Mat4,
    proj: Mat4,
};

const PerObject = struct {
    model: Mat4,
};

pub var state: ShaderState = .{
    .view = Mat4.identity(),
    .proj = Mat4.identity(),
};

var per_object: PerObject = .{ .model = Mat4.identity() };

var ubo: gl.uint = 0;
var per_object_ubo: gl.uint = 0;
var initialized = false;

pub fn init() !void {
    assert(!initialized);
    initialized = true;

    gl.CreateBuffers(1, @ptrCast(&ubo));
    gl.NamedBufferStorage(ubo, @sizeOf(ShaderState), &state, gl.DYNAMIC_STORAGE_BIT);
    gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, ubo);

    gl.CreateBuffers(1, @ptrCast(&per_object_ubo));
    gl.NamedBufferStorage(per_object_ubo, @sizeOf(PerObject), &per_object, gl.DYNAMIC_STORAGE_BIT);
    gl.BindBufferBase(gl.UNIFORM_BUFFER, 1, per_object_ubo);

    assert(ubo != 0);
    assert(per_object_ubo != 0);
    assert(initialized);
}

pub fn update_ubo() void {
    gl.NamedBufferSubData(ubo, 0, @sizeOf(ShaderState), &state);
}

pub fn update_per_object(model: *const Mat4) void {
    per_object.model = model.*;
    gl.NamedBufferSubData(per_object_ubo, 0, @sizeOf(PerObject), &per_object);
}

pub fn deinit() void {
    assert(initialized);
    initialized = false;

    gl.DeleteBuffers(1, @ptrCast(&ubo));
    gl.DeleteBuffers(1, @ptrCast(&per_object_ubo));

    assert(!initialized);
}

pub const Shader = struct {
    shader_program: gl.uint = 0,

    pub fn init(vs_src: [:0]const u8, fs_src: [:0]const u8) !Shader {
        var self = Shader{};

        const vert = try compile_shader(vs_src, gl.VERTEX_SHADER);
        const frag = try compile_shader(fs_src, gl.FRAGMENT_SHADER);
        self.shader_program = try link_shader(vert, frag);

        return self;
    }

    pub fn bind(self: *const Shader) void {
        gl.UseProgram(self.shader_program);
    }

    pub fn deinit(self: *Shader) void {
        gl.DeleteProgram(self.shader_program);
        self.shader_program = 0;
    }
};

fn compile_shader(source: [:0]const u8, shader_type: gl.uint) !gl.uint {
    const s = gl.CreateShader(shader_type);

    gl.ShaderSource(s, 1, @ptrCast(&source.ptr), null);
    gl.CompileShader(s);

    var success: c_uint = 0;
    gl.GetShaderiv(s, gl.COMPILE_STATUS, @ptrCast(&success));
    if (success == 0) {
        var buf: [512]u8 = @splat(0);
        var len: c_uint = 0;
        gl.GetShaderInfoLog(s, 512, @ptrCast(&len), &buf);
        Util.engine_logger.err("Shader compilation failed:\n{s}\n", .{buf[0..len]});
        return error.ShaderCompilationFailed;
    }

    return s;
}

/// Consumes the input shaders and returns a linked program.
/// You cannot use vert or frag shaders after linking!
fn link_shader(vert: gl.uint, frag: gl.uint) !gl.uint {
    const program = gl.CreateProgram();
    gl.AttachShader(program, vert);
    gl.AttachShader(program, frag);
    gl.LinkProgram(program);

    var success: c_uint = 0;
    gl.GetProgramiv(program, gl.LINK_STATUS, @ptrCast(&success));
    if (success == 0) {
        var buf: [512]u8 = @splat(0);
        var len: c_uint = 0;
        gl.GetProgramInfoLog(program, 512, @ptrCast(&len), &buf);
        Util.engine_logger.err("Program linking failed:\n{s}\n", .{buf[0..len]});
        return error.ProgramLinkingFailed;
    }

    gl.DeleteShader(vert);
    gl.DeleteShader(frag);
    gl.UseProgram(program);

    return program;
}
