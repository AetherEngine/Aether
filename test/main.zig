const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const Audio = ae.Audio;
const State = Core.State;
const Options = @import("options");

pub const std_options = Util.std_options;

const Vertex = struct {
    pos: [3]f32,
    color: [4]u8,
    uv: [2]f32,

    pub const Attributes = Rendering.Pipeline.attributes_from_struct(@This(), &[_]Rendering.Pipeline.AttributeSpec{
        .{ .field = "pos", .location = 0 },
        .{ .field = "color", .location = 1 },
        .{ .field = "uv", .location = 2 },
    });
    pub const Layout = Rendering.Pipeline.layout_from_struct(@This(), &Attributes);
};

const MyMesh = Rendering.Mesh(Vertex);

const MyState = struct {
    mesh: MyMesh,
    transform: Rendering.Transform,
    texture: Rendering.Texture,
    io: std.Io,

    fn init(ctx: *anyopaque) anyerror!void {
        var self = Util.ctx_to_self(MyState, ctx);

        if (Options.config.gfx == .opengl) {
            const vert align(@alignOf(u32)) = @embedFile("shaders/basic.vert").*;
            const frag align(@alignOf(u32)) = @embedFile("shaders/basic.frag").*;
            pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);
        } else {
            const vert_spv align(@alignOf(u32)) = @embedFile("vertex_shader").*;
            const frag_spv align(@alignOf(u32)) = @embedFile("fragment_shader").*;
            pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert_spv, &frag_spv);
        }

        self.mesh = try MyMesh.new(Util.allocator(), pipeline);
        self.transform = Rendering.Transform.new();

        // const png_bytes = @embedFile("test.png");
        self.texture = try Rendering.Texture.load(Util.allocator(), self.io, "test.png");

        try self.mesh.vertices.appendSlice(Util.allocator(), &.{
            Vertex{ .pos = .{ -0.5, -0.5, 0.0 }, .color = .{ 255, 255, 255, 255 }, .uv = .{ 0.0, 1.0 } },
            Vertex{ .pos = .{ 0.5, -0.5, 0.0 }, .color = .{ 255, 255, 255, 255 }, .uv = .{ 1.0, 1.0 } },
            Vertex{ .pos = .{ 0.0, 0.5, 0.0 }, .color = .{ 255, 255, 255, 255 }, .uv = .{ 0.5, 0.0 } },
        });
        self.mesh.update();
    }

    fn deinit(ctx: *anyopaque) void {
        var self = Util.ctx_to_self(MyState, ctx);
        self.texture.deinit(Util.allocator());
        self.mesh.deinit(Util.allocator());
        Rendering.Pipeline.deinit(pipeline);
    }

    fn tick(ctx: *anyopaque) anyerror!void {
        _ = ctx;
    }

    fn update(ctx: *anyopaque, dt: f32) anyerror!void {
        var self = Util.ctx_to_self(MyState, ctx);
        self.transform.rot.z += 60.0 * dt;
    }

    fn draw(ctx: *anyopaque, _: f32) anyerror!void {
        var self = Util.ctx_to_self(MyState, ctx);

        Rendering.gfx.api.set_proj_matrix(&Math.Mat4.orthographicRh(
            2 * @as(f32, @floatFromInt(Rendering.gfx.surface.get_width())) / @as(f32, @floatFromInt(Rendering.gfx.surface.get_height())),
            2,
            0,
            1,
        ));

        Rendering.Pipeline.bind(pipeline);
        self.texture.bind();
        self.mesh.draw(&self.transform.get_matrix());
    }

    pub fn state(self: *MyState) State {
        return .{ .ptr = self, .tab = &.{
            .init = init,
            .deinit = deinit,
            .tick = tick,
            .update = update,
            .draw = draw,
        } };
    }
};

var pipeline: Rendering.Pipeline.Handle = undefined;

pub fn main(init: std.process.Init) !void {
    var state: MyState = undefined;
    state.io = init.io;

    try ae.App.init(init.io, 1280, 720, "Aether", Options.config.gfx, false, false, &state.state());
    defer ae.App.deinit(init.io);

    try ae.App.main_loop(init.io);
}
