const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const Audio = ae.Audio;
const State = Core.State;

// TODO: Make these options stuff nice
pub const std_options = Util.std_options;

const sdk = if (ae.platform == .psp) @import("pspsdk") else void;
comptime {
    if (sdk != void)
        asm (sdk.extra.module.module_info("My App Name", .{ .mode = .User }, 1, 0));
}

pub const psp_stack_size: u32 = 256 * 1024;

// PSP: override panic/IO handlers that would otherwise pull in posix symbols.
pub const panic = if (ae.platform == .psp) sdk.extra.debug.panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (ae.platform == .psp) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io = if (ae.platform == .psp) sdk.extra.Io.psp_io else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd = if (ae.platform == .psp) psp_cwd else null;
fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}

const Vertex = extern struct {
    uv: [2]i16,
    color: u32,
    pos: [3]i16,
    _pad: i16 = 0,

    pub const Attributes = Rendering.Pipeline.attributes_from_struct(@This(), &[_]Rendering.Pipeline.AttributeSpec{
        .{ .field = "pos", .location = 0, .usage = .position },
        .{ .field = "color", .location = 1, .usage = .color },
        .{ .field = "uv", .location = 2, .usage = .uv },
    });
    pub const Layout = Rendering.Pipeline.layout_from_struct(@This(), &Attributes);
};

const MyMesh = Rendering.Mesh(Vertex);

const MAX_GRASS_VOICES = 4;
const Vec3 = Math.Vec3;

const MyState = struct {
    mesh: MyMesh,
    transform: Rendering.Transform,
    texture: Rendering.Texture,
    music_data: []u8,
    music_reader: std.Io.Reader,
    grass_data: []u8,
    grass_readers: [MAX_GRASS_VOICES]std.Io.Reader,
    grass_tick: u32,
    grass_spawn: u32,

    fn load_wav(engine: *ae.Engine, path: []const u8) ![]u8 {
        var file = try std.Io.Dir.cwd().openFile(engine.io, path, .{});
        defer file.close(engine.io);

        var tmp: [4096]u8 = undefined;
        var rdr = file.reader(engine.io, &tmp);

        var riff_hdr: [8]u8 = undefined;
        try rdr.interface.readSliceAll(&riff_hdr);
        const file_size: usize = @as(usize, std.mem.readInt(u32, riff_hdr[4..8], .little)) + 8;

        const buf = try engine.allocator(.audio).alloc(u8, file_size);
        @memcpy(buf[0..8], &riff_hdr);
        try rdr.interface.readSliceAll(buf[8..]);
        return buf;
    }

    fn init(ctx: *anyopaque, engine: *ae.Engine) anyerror!void {
        var self = ae.ctx_to_self(MyState, ctx);
        const vert align(@alignOf(u32)) = @embedFile("basic_vert").*;
        const frag align(@alignOf(u32)) = @embedFile("basic_frag").*;
        pipeline = try Rendering.Pipeline.new(Vertex.Layout, &vert, &frag);

        const render = engine.allocator(.render);

        self.mesh = try MyMesh.new(render, pipeline);
        self.transform = Rendering.Transform.new();

        self.texture = try Rendering.Texture.load(engine.io, render, "test.png");
        try self.mesh.append(render, &.{
            Vertex{ .pos = .{ -16383, -16383, 0 }, .color = 0xFF0000FF, .uv = .{ 0, 32767 } },
            Vertex{ .pos = .{ 16383, -16383, 0 }, .color = 0xFF00FF00, .uv = .{ 32767, 32767 } },
            Vertex{ .pos = .{ 0, 16383, 0 }, .color = 0xFFFF0000, .uv = .{ 16383, 0 } },
        });
        self.mesh.update();

        // -- background music --
        self.music_data = try load_wav(engine, "calm1.wav");
        self.music_reader = .fixed(self.music_data);
        const music_stream = try Audio.wav.open(&self.music_reader);
        _ = try Audio.play(music_stream, .{ .priority = .critical });

        // -- spatial SFX data --
        self.grass_data = try load_wav(engine, "grass1.wav");
        self.grass_readers = @splat(.fixed(&.{}));
        self.grass_tick = 0;
        self.grass_spawn = 0;

        // Listener at origin, facing -Z
        Audio.set_listener(Vec3.zero(), Vec3.new(0, 0, -1), Vec3.new(0, 1, 0));

        engine.report();
    }

    fn deinit(ctx: *anyopaque, engine: *ae.Engine) void {
        var self = ae.ctx_to_self(MyState, ctx);
        const render = engine.allocator(.render);
        self.texture.deinit(render);
        self.mesh.deinit(render);
        Rendering.Pipeline.deinit(pipeline);
    }

    fn tick(ctx: *anyopaque, _: *ae.Engine) anyerror!void {
        var self = ae.ctx_to_self(MyState, ctx);
        self.grass_tick += 1;

        // Every 30 ticks (~1.5 s at 20 Hz), spawn a grass sound.
        if (self.grass_tick >= 30) {
            self.grass_tick = 0;

            const i = self.grass_spawn % MAX_GRASS_VOICES;
            const n = self.grass_spawn;
            self.grass_spawn +%= 1;

            // Rotate around the listener at varying distances.
            const angle = @as(f32, @floatFromInt(n)) * std.math.pi / 3.0;
            const dist = 1.0 + @as(f32, @floatFromInt(n % 5)) * 4.0;
            const pos = Vec3.new(@cos(angle) * dist, 0, @sin(angle) * dist);

            self.grass_readers[i] = .fixed(self.grass_data);
            const stream = Audio.wav.open(&self.grass_readers[i]) catch return;
            _ = Audio.play_at(stream, pos, .{
                .ref_distance = 1.0,
                .max_distance = 25.0,
            }) catch return;

            Util.game_logger.info("grass at ({d:.1}, 0, {d:.1})  dist={d:.1}", .{ pos.x, pos.z, dist });
        }
    }

    fn update(ctx: *anyopaque, _: *ae.Engine, dt: f32, _: *const Util.BudgetContext) anyerror!void {
        var self = ae.ctx_to_self(MyState, ctx);
        self.transform.rot.z += 60.0 * dt;
    }

    fn draw(ctx: *anyopaque, _: *ae.Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {
        var self = ae.ctx_to_self(MyState, ctx);

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
    const memory = try init.arena.allocator().alloc(u8, 32 * 1024 * 1024);

    var state: MyState = undefined;
    var engine: ae.Engine = undefined;
    try engine.init(init.io, memory, .{
        .memory = .{
            .render = 12 * 1024 * 1024,
            .audio = 10 * 1024 * 1024,
            .game = 2 * 1024 * 1024,
            .user = 8 * 1024 * 1024,
        },
        .resizable = true,
    }, &state.state());
    defer engine.deinit();
    try engine.run();
}
