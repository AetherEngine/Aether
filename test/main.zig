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

// PSP, 3DS, and Switch override panic/IO handlers that would otherwise
// pull in posix symbols (Io.Threaded references std.posix decls that
// don't exist for these targets). 3DS and Switch use Aether's newlib-backed
// baseline so debug prints and file IO go through the backend instead of
// dereferencing an undefined Io implementation.
const is_freestanding_console = ae.platform == .psp or ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch;
// 3DS routes panics through err:f; Switch keeps `no_panic` while the debug IO
// baseline is intentionally small.
pub const panic = if (ae.platform == .psp) sdk.extra.debug.panic else if (ae.platform == .nintendo_3ds) ae.ThreeDS.panic else if (ae.platform == .nintendo_switch) std.debug.no_panic else std.debug.FullPanic(std.debug.defaultPanic);
pub const std_options_debug_threaded_io = if (is_freestanding_console) null else std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io: std.Io =
    if (ae.platform == .psp) sdk.extra.Io.psp_io else if (ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch) ae.Cio.io() else std.Io.Threaded.global_single_threaded.io();
pub const std_options_cwd =
    if (ae.platform == .psp) psp_cwd else if (ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch) ae.Cio.cwd else null;
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

const BATCH_A_TRIANGLES = 61;
const BATCH_B_TRIANGLES = 78;
const MAX_GRASS_VOICES = 4;
const Vec3 = Math.Vec3;

fn rgba(r: u8, g: u8, b: u8) u32 {
    return @as(u32, r) |
        (@as(u32, g) << 8) |
        (@as(u32, b) << 16) |
        (@as(u32, 0xFF) << 24);
}

const BatchAColors = [_]u32{
    rgba(255, 62, 62),
    rgba(255, 170, 54),
    rgba(245, 235, 80),
    rgba(76, 210, 130),
    rgba(58, 190, 235),
    rgba(145, 105, 255),
};

const BatchBColors = [_]u32{
    rgba(48, 110, 255),
    rgba(56, 205, 190),
    rgba(225, 88, 180),
    rgba(240, 150, 70),
    rgba(210, 230, 80),
    rgba(255, 255, 255),
};

fn snorm16(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v, -1.0, 1.0) * 32767.0);
}

fn vertex(x: f32, y: f32, color: u32, u: f32, v: f32) Vertex {
    return .{
        .pos = .{ snorm16(x), snorm16(y), 0 },
        .color = color,
        .uv = .{ snorm16(u), snorm16(v) },
    };
}

fn appendTriangle(
    alloc: std.mem.Allocator,
    mesh: *MyMesh,
    a: [2]f32,
    b: [2]f32,
    c: [2]f32,
    ca: u32,
    cb: u32,
    cc: u32,
) !void {
    try mesh.append(alloc, &.{
        vertex(a[0], a[1], ca, 0.5, 0.0),
        vertex(b[0], b[1], cb, 0.0, 1.0),
        vertex(c[0], c[1], cc, 1.0, 1.0),
    });
}

fn orientedPoint(cx: f32, cy: f32, lx: f32, ly: f32, angle: f32) [2]f32 {
    const c = @cos(angle);
    const s = @sin(angle);
    return .{
        cx + lx * c - ly * s,
        cy + lx * s + ly * c,
    };
}

fn appendOrientedTriangle(
    alloc: std.mem.Allocator,
    mesh: *MyMesh,
    cx: f32,
    cy: f32,
    sx: f32,
    sy: f32,
    angle: f32,
    c0: u32,
    c1: u32,
    c2: u32,
) !void {
    try appendTriangle(
        alloc,
        mesh,
        orientedPoint(cx, cy, 0.0, sy, angle),
        orientedPoint(cx, cy, -sx, -sy, angle),
        orientedPoint(cx, cy, sx, -sy, angle),
        c0,
        c1,
        c2,
    );
}

fn buildBatchA(alloc: std.mem.Allocator, mesh: *MyMesh) !void {
    try mesh.vertices.ensureTotalCapacity(alloc, BATCH_A_TRIANGLES * 3);

    try appendTriangle(alloc, mesh, .{ -0.44, -0.40 }, .{ 0.44, -0.40 }, .{ 0.0, 0.52 }, BatchAColors[0], BatchAColors[3], BatchAColors[5]);

    const spoke_count = 36;
    for (0..spoke_count) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(spoke_count));
        const angle = t * std.math.pi * 2.0;
        const tip_radius = 0.78 + @sin(angle * 3.0) * 0.04;
        const base_radius = 0.31 + @cos(angle * 2.0) * 0.035;
        const half_width = 0.075 + @sin(angle * 5.0) * 0.012;
        const tip = [2]f32{ @cos(angle) * tip_radius, @sin(angle) * tip_radius };
        const left = [2]f32{ @cos(angle - half_width) * base_radius, @sin(angle - half_width) * base_radius };
        const right = [2]f32{ @cos(angle + half_width) * base_radius, @sin(angle + half_width) * base_radius };

        try appendTriangle(
            alloc,
            mesh,
            tip,
            left,
            right,
            BatchAColors[i % BatchAColors.len],
            BatchAColors[(i + 2) % BatchAColors.len],
            BatchAColors[(i + 4) % BatchAColors.len],
        );
    }

    const marker_count = 24;
    for (0..marker_count) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(marker_count));
        const angle = t * std.math.pi * 2.0;
        const radius = 0.56 + if (i % 2 == 0) @as(f32, 0.045) else -0.025;
        const size = 0.032 + @as(f32, @floatFromInt(i % 4)) * 0.006;
        try appendOrientedTriangle(
            alloc,
            mesh,
            @cos(angle) * radius,
            @sin(angle) * radius,
            size * 0.75,
            size,
            angle + std.math.pi * 0.5,
            BatchAColors[(i + 1) % BatchAColors.len],
            BatchAColors[(i + 3) % BatchAColors.len],
            BatchAColors[(i + 5) % BatchAColors.len],
        );
    }
}

fn buildBatchB(alloc: std.mem.Allocator, mesh: *MyMesh) !void {
    try mesh.vertices.ensureTotalCapacity(alloc, BATCH_B_TRIANGLES * 3);

    const cols = 9;
    const rows = 6;
    for (0..rows) |row| {
        for (0..cols) |col| {
            const idx = row * cols + col;
            const fx = @as(f32, @floatFromInt(col)) / @as(f32, @floatFromInt(cols - 1));
            const fy = @as(f32, @floatFromInt(row)) / @as(f32, @floatFromInt(rows - 1));
            const x = -0.88 + fx * 1.76;
            const y = -0.67 + fy * 1.34;
            const size = 0.04 + @as(f32, @floatFromInt((idx + row) % 5)) * 0.008;
            const angle = @as(f32, @floatFromInt(idx)) * 0.43 + @sin(fy * std.math.pi) * 0.35;

            try appendOrientedTriangle(
                alloc,
                mesh,
                x,
                y,
                size * (0.72 + fx * 0.35),
                size,
                angle,
                BatchBColors[idx % BatchBColors.len],
                BatchBColors[(idx + 2) % BatchBColors.len],
                BatchBColors[(idx + 4) % BatchBColors.len],
            );
        }
    }

    const wave_count = 24;
    for (0..wave_count) |i| {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(wave_count - 1));
        const x = -0.94 + t * 1.88;
        const y = 0.78 + @sin(t * std.math.pi * 6.0) * 0.095;
        const size = 0.035 + @as(f32, @floatFromInt(i % 3)) * 0.007;
        const angle = t * std.math.pi * 4.0;

        try appendOrientedTriangle(
            alloc,
            mesh,
            x,
            y,
            size,
            size * 1.6,
            angle,
            BatchBColors[(i + 5) % BatchBColors.len],
            BatchBColors[(i + 1) % BatchBColors.len],
            BatchBColors[(i + 3) % BatchBColors.len],
        );
    }
}

const MyState = struct {
    batch_a: MyMesh,
    batch_b: MyMesh,
    batch_a_transform: Rendering.Transform,
    batch_b_transform: Rendering.Transform,
    texture: Rendering.Texture,
    music_data: []const u8,
    music_reader: std.Io.Reader,
    grass_data: []const u8,
    grass_readers: [MAX_GRASS_VOICES]std.Io.Reader,
    grass_tick: u32,
    grass_spawn: u32,
    time: f32,

    fn load_wav(engine: *ae.Engine, path: []const u8) ![]u8 {
        var file = try engine.dirs.resources.openFile(engine.io, path, .{});
        defer file.close(engine.io);

        var tmp: [4096]u8 = undefined;
        var rdr = if (ae.platform == .nintendo_3ds or ae.platform == .nintendo_switch)
            file.readerStreaming(engine.io, &tmp)
        else
            file.reader(engine.io, &tmp);

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

        self.batch_a = try MyMesh.new(render, pipeline);
        self.batch_b = try MyMesh.new(render, pipeline);
        self.batch_a_transform = Rendering.Transform.new();
        self.batch_b_transform = Rendering.Transform.new();

        self.texture = try Rendering.Texture.load(engine.io, engine.dirs.resources, render, "test.png");

        try buildBatchA(render, &self.batch_a);
        try buildBatchB(render, &self.batch_b);
        self.batch_a.update();
        self.batch_b.update();

        self.music_data = &.{};
        self.music_reader = .fixed(&.{});
        self.grass_data = &.{};
        self.grass_readers = @splat(.fixed(&.{}));
        self.grass_tick = 0;
        self.grass_spawn = 0;
        self.time = 0.0;

        if (!Audio.enabled) return;

        // -- background music --
        self.music_data = try load_wav(engine, "calm1.wav");
        self.music_reader = .fixed(self.music_data);
        const music_stream = try Audio.wav.open(&self.music_reader);
        _ = try Audio.play(music_stream, .{ .priority = .critical });

        // -- spatial SFX data --
        self.grass_data = try load_wav(engine, "grass1.wav");

        // Listener at origin, facing -Z
        Audio.set_listener(Vec3.zero(), Vec3.new(0, 0, -1), Vec3.new(0, 1, 0));

        engine.report();
    }

    fn deinit(ctx: *anyopaque, engine: *ae.Engine) void {
        var self = ae.ctx_to_self(MyState, ctx);
        const render = engine.allocator(.render);
        self.texture.deinit(render);
        self.batch_b.deinit(render);
        self.batch_a.deinit(render);
        Rendering.Pipeline.deinit(pipeline);
    }

    fn tick(ctx: *anyopaque, _: *ae.Engine) anyerror!void {
        if (!Audio.enabled) return;

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
        self.time += dt;

        self.batch_a_transform.rot.z += 76.0 * dt;
        self.batch_b_transform.rot.z -= 18.0 * dt;

        const batch_a_pulse = 1.0 + @sin(self.time * 1.8) * 0.06;
        const batch_b_x = 1.0 + @cos(self.time * 0.9) * 0.035;
        const batch_b_y = 1.0 + @sin(self.time * 1.1) * 0.035;

        self.batch_a_transform.scale = Vec3.new(batch_a_pulse, batch_a_pulse, 1.0);
        self.batch_b_transform.scale = Vec3.new(batch_b_x, batch_b_y, 1.0);
        self.batch_b_transform.pos = Vec3.new(@sin(self.time * 0.7) * 0.075, @cos(self.time * 0.5) * 0.04, 0.0);
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
        Rendering.gfx.api.set_depth_write(false);
        self.texture.bind();
        self.batch_b.draw(&self.batch_b_transform.get_matrix());
        self.batch_a.draw(&self.batch_a_transform.get_matrix());
        Rendering.gfx.api.set_depth_write(true);
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
    const mib = 1024 * 1024;
    const render_memory_bytes = if (ae.platform == .nintendo_3ds) 28 * 1024 * 1024 else 12 * 1024 * 1024;
    const main_memory_bytes = if (ae.platform == .nintendo_3ds) 24 * 1024 * 1024 else 32 * 1024 * 1024;
    const memory = init.arena.allocator().alloc(u8, main_memory_bytes) catch |err| switch (err) {
        error.OutOfMemory => std.debug.panic(
            "MainOOMMiB m={} r={} h={} l={}",
            .{
                main_memory_bytes / mib,
                render_memory_bytes / mib,
                ae.nintendo_3ds_heap_size / mib,
                ae.nintendo_3ds_linear_heap_size / mib,
            },
        ),
    };

    var state: MyState = undefined;
    var engine: ae.Engine = undefined;
    engine.init(init.io, init.environ_map, memory, .{
        .memory = .{
            .render = render_memory_bytes,
            .audio = 10 * 1024 * 1024,
            .game = 2 * 1024 * 1024,
            .user = 8 * 1024 * 1024,
        },
        .render_capacity = if (ae.platform == .nintendo_3ds) render_memory_bytes else null,
        .resizable = true,
    }, &state.state()) catch |err| switch (err) {
        error.OutOfMemory => return error.EngineInitOutOfMemory,
        else => return err,
    };
    defer engine.deinit();
    engine.run() catch |err| switch (err) {
        error.OutOfMemory => return error.EngineRunOutOfMemory,
        else => return err,
    };
}
