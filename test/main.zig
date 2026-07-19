const std = @import("std");
const ae = @import("aether");
const Math = ae.Math;
const Core = ae.Core;
const Util = ae.Util;
const Rendering = ae.Rendering;
const Audio = ae.Audio;
const State = Core.State;

pub const aether_options: ae.Options = .{
    .title = "Aether",
    .app_name = "Aether",
    .psp = .{
        .module_name = "My App Name",
        .stack_size = 256 * 1024,
    },
};

const Vertex = Rendering.Vertex;
const MyMesh = Rendering.Mesh(Vertex);
const MyMeshData = Rendering.MeshData(Vertex);

const BATCH_A_TRIANGLES = 61;
const BATCH_B_TRIANGLES = 78;
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
    mesh: *MyMeshData,
    cx: f32,
    cy: f32,
    sx: f32,
    sy: f32,
    angle: f32,
    c0: u32,
    c1: u32,
    c2: u32,
) !void {
    const a = orientedPoint(cx, cy, 0.0, sy, angle);
    const b = orientedPoint(cx, cy, -sx, -sy, angle);
    const c = orientedPoint(cx, cy, sx, -sy, angle);
    try mesh.add_tri(
        alloc,
        vertex(a[0], a[1], c0, 0.5, 0.0),
        vertex(b[0], b[1], c1, 0.0, 1.0),
        vertex(c[0], c[1], c2, 1.0, 1.0),
    );
}

fn buildBatchA(alloc: std.mem.Allocator, mesh: *MyMeshData) !void {
    try mesh.vertices.ensureTotalCapacity(alloc, BATCH_A_TRIANGLES * 3);

    try mesh.add_tri(
        alloc,
        vertex(-0.44, -0.40, BatchAColors[0], 0.5, 0.0),
        vertex(0.44, -0.40, BatchAColors[3], 0.0, 1.0),
        vertex(0.0, 0.52, BatchAColors[5], 1.0, 1.0),
    );

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

        try mesh.add_tri(
            alloc,
            vertex(tip[0], tip[1], BatchAColors[i % BatchAColors.len], 0.5, 0.0),
            vertex(left[0], left[1], BatchAColors[(i + 2) % BatchAColors.len], 0.0, 1.0),
            vertex(right[0], right[1], BatchAColors[(i + 4) % BatchAColors.len], 1.0, 1.0),
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

fn buildBatchB(alloc: std.mem.Allocator, mesh: *MyMeshData) !void {
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

pub const MyState = struct {
    batch_a_data: MyMeshData,
    batch_b_data: MyMeshData,
    batch_a: MyMesh,
    batch_b: MyMesh,
    batch_a_transform: Rendering.Transform,
    batch_b_transform: Rendering.Transform,
    texture: Rendering.Texture,
    music_buffer: Audio.SoundBufferHandle,
    grass_buffer: Audio.SoundBufferHandle,
    grass_tick: u32,
    grass_spawn: u32,
    time: f32,

    fn init(ctx: *anyopaque, engine: *ae.Engine) anyerror!void {
        var self = ae.ctx_to_self(MyState, ctx);

        const render = engine.allocator(.render);

        self.batch_a_data = try MyMeshData.init(render);
        errdefer self.batch_a_data.deinit(render);
        self.batch_b_data = try MyMeshData.init(render);
        errdefer self.batch_b_data.deinit(render);
        self.batch_a = try MyMesh.init(&.{});
        errdefer self.batch_a.deinit();
        self.batch_b = try MyMesh.init(&.{});
        errdefer self.batch_b.deinit();
        self.batch_a_transform = Rendering.Transform.new();
        self.batch_b_transform = Rendering.Transform.new();

        self.texture = try Rendering.Texture.load(engine.io, engine.dirs.resources, render, "test.png", &.{});

        try buildBatchA(render, &self.batch_a_data);
        try buildBatchB(render, &self.batch_b_data);
        self.batch_a.update(&self.batch_a_data);
        self.batch_b.update(&self.batch_b_data);

        self.music_buffer = .none;
        self.grass_buffer = .none;
        self.grass_tick = 0;
        self.grass_spawn = 0;
        self.time = 0.0;

        if (!Audio.enabled) return;

        // -- background music --
        self.music_buffer = try Audio.load_wav(engine.io, engine.dirs.resources, engine.allocator(.audio), "calm1.wav");
        _ = try Audio.play_buffer(self.music_buffer, &.{ .priority = .critical });

        // -- spatial SFX data --
        self.grass_buffer = try Audio.load_wav(engine.io, engine.dirs.resources, engine.allocator(.audio), "grass1.wav");

        // Listener at origin, facing -Z
        Audio.set_listener(Vec3.zero(), Vec3.new(0, 0, -1), Vec3.new(0, 1, 0));

        engine.report();
    }

    fn deinit(ctx: *anyopaque, engine: *ae.Engine) void {
        var self = ae.ctx_to_self(MyState, ctx);
        const render = engine.allocator(.render);
        if (!self.grass_buffer.is_null()) Audio.destroy_buffer(self.grass_buffer);
        if (!self.music_buffer.is_null()) Audio.destroy_buffer(self.music_buffer);
        self.texture.deinit(render);
        self.batch_b.deinit();
        self.batch_a.deinit();
        self.batch_b_data.deinit(render);
        self.batch_a_data.deinit(render);
    }

    fn tick(ctx: *anyopaque, _: *ae.Engine) anyerror!void {
        if (!Audio.enabled) return;

        var self = ae.ctx_to_self(MyState, ctx);
        self.grass_tick += 1;

        // Every 30 ticks (~1.5 s at 20 Hz), spawn a grass sound.
        if (self.grass_tick >= 30) {
            self.grass_tick = 0;

            const n = self.grass_spawn;
            self.grass_spawn +%= 1;

            // Rotate around the listener at varying distances.
            const angle = @as(f32, @floatFromInt(n)) * std.math.pi / 3.0;
            const dist = 1.0 + @as(f32, @floatFromInt(n % 5)) * 4.0;
            const pos = Vec3.new(@cos(angle) * dist, 0, @sin(angle) * dist);

            _ = Audio.play_buffer_at(self.grass_buffer, pos, &.{
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

        Rendering.set_state(&.{
            .texture = self.texture.handle,
            .proj = Math.Mat4.orthographicRh(
                2 * @as(f32, @floatFromInt(Rendering.gfx.surface.get_width())) / @as(f32, @floatFromInt(Rendering.gfx.surface.get_height())),
                2,
                0,
                1,
            ),
            .depth_write = false,
        });

        self.batch_b.draw(&self.batch_b_transform.get_matrix());
        self.batch_a.draw(&self.batch_a_transform.get_matrix());
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

pub fn main(init: std.process.Init) !void {
    const mib = 1024 * 1024;
    const memory_config: ae.Util.MemoryConfig = .{
        .render = 12 * 1024 * 1024,
        .audio = 10 * 1024 * 1024,
        .game = 2 * 1024 * 1024,
        .frame = 2 * 1024 * 1024,
        .user = 8 * 1024 * 1024,
    };
    const main_memory_bytes = memory_config.total();
    const memory = init.gpa.alignedAlloc(u8, .fromByteUnits(16), main_memory_bytes) catch |err| switch (err) {
        error.OutOfMemory => std.debug.panic(
            "MainOOMMiB m={}",
            .{
                main_memory_bytes / mib,
            },
        ),
    };
    defer init.gpa.free(memory);

    var state: MyState = undefined;
    var engine: ae.Engine = undefined;
    engine.init(init.io, init.environ_map, memory, &.{
        .memory = memory_config,
        .title = aether_options.title,
        .app_name = ae.AppOptions.resolveAppName(aether_options),
        .resizable = true,
    }, &state.state()) catch |err| switch (err) {
        error.OutOfMemory => return error.EngineInitOutOfMemory,
        else => return err,
    };
    defer engine.deinit();
    engine.run() catch |err| switch (err) {
        error.StateTransitionFailed => {
            if (engine.last_transition_failure()) |state_err| {
                Util.game_logger.err("state transition failed: {s}", .{@errorName(state_err)});
            }
            return error.EngineStateTransitionFailed;
        },
        error.OutOfMemory => return error.EngineRunOutOfMemory,
        else => return err,
    };
}
