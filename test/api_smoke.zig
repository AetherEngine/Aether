//! Compile-only API coverage. With no arguments this application performs no
//! engine setup. --exercise runs CPU geometry and thread lifetime checks only.
//! Exported probes force native/GPU service bodies through target compilation;
//! they are not called by main and require a correctly initialized test harness.
const std = @import("std");
const ae = @import("aether");
const Rendering = ae.Rendering;
const Vec3 = ae.Math.Vec3;
const Image = ae.Util.Image;

comptime {
    _ = &@import("ui_api_smoke.zig").aether_api_smoke_ui_prepare;
    _ = &@import("ui_api_smoke.zig").aether_api_smoke_ui_draw;
}

pub const aether_options: ae.Options = .{
    .title = "Aether API smoke",
    .app_name = "aether-api-smoke",
    .psp = .{ .module_name = "Aether API smoke", .stack_size = 256 * 1024 },
};

pub fn main(init: std.process.Init) !void {
    if (comptime std.process.Args.Vector == void) return;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 1 and std.mem.eql(u8, args[1], "--exercise")) try exercise(init);
}

export fn aether_api_smoke_cpu(init: *const std.process.Init) bool {
    exercise(init.*) catch return false;
    return true;
}

fn exercise(init: std.process.Init) !void {
    const position = Vec3.zero();
    var camera: Rendering.Camera = .{
        .target = &position,
        .fov = 70,
        .yaw = 10,
        .pitch = 5,
        .near_plane = 0.1,
        .far_plane = 100,
        .view_adjustment = ae.Math.Mat4.identity(),
    };
    try camera.update_for_aspect(1.5);
    const matrices = try camera.matrices(1.5);
    const bounds: ae.Math.Aabb = .{ .min = Vec3.new(-1, -1, -5), .max = Vec3.new(1, 1, -3) };
    std.mem.doNotOptimizeAway(matrices.frustum.contains_aabb(bounds));
    std.mem.doNotOptimizeAway(try bounds.ray_intersection(position, Vec3.new(0, 0, -1), 0, 10));
    std.mem.doNotOptimizeAway(try bounds.sweep(.{ .min = Vec3.zero(), .max = Vec3.one() }, Vec3.new(0, 0, 5)));
    var ray = try ae.Math.GridRay.init(position, Vec3.new(0, 0, -1), 4);
    while (try ray.next()) |cell| std.mem.doNotOptimizeAway(cell);

    const source: Image.View = .{
        .width = 2,
        .height = 1,
        .mode = .rgba4444,
        .data = &.{ 0x0f, 0xf0, 0xf0, 0xf0 },
    };
    var target_pixels: [4]u8 = undefined;
    const destination: Image.MutableView = .{ .width = 2, .height = 1, .mode = .rgba4444, .data = &target_pixels };
    try destination.copy_region(source, .{ .width = 2, .height = 1 }, 0, 0);
    const flipbook = try Rendering.Flipbook.init(source, .{
        .frame_width = 1,
        .frame_height = 1,
        .frame_count = 2,
        .frames_per_second = 4,
        .playback = .ping_pong,
    });
    try flipbook.copy_to_image(destination, source, try flipbook.frame_at(0.25), 0, 0);
    std.mem.doNotOptimizeAway(try destination.view().get_pixel(0, 0));

    var batch = try Rendering.BillboardBatcher.init(init.gpa, .{ .capacity = 4, .units_per_world_unit = 128 });
    defer batch.deinit();

    try batch.begin(position, try Rendering.BillboardBatcher.Basis.from_view(matrices.view));
    try batch.add(.{ .position = Vec3.new(0, 0, -4), .size = .{ 1, 1 } });
    try batch.add(.{ .position = Vec3.new(2, 0, -4), .size = .{ 1, 2 }, .facing = .{ .axis_y = position } });
    std.mem.doNotOptimizeAway(batch.model_matrix());
    std.mem.doNotOptimizeAway(batch.encoding.decode(batch.data.vertices.items[0].pos));

    const system = ae.System.info();
    std.mem.doNotOptimizeAway(system);
    if (system.background_workers) {
        var counter = std.atomic.Value(u32).init(0);
        const thread = try ae.Util.Thread.spawn(.{ .allocator = init.gpa, .io = init.io }, thread_probe, .{&counter});
        thread.join();
        if (counter.load(.acquire) != 1) return error.ThreadDidNotRun;
    }
    const executor = try ae.Jobs.Executor.init(init.gpa, init.io, .{ .capacity = 2 });
    defer executor.deinit();

    var completed: u32 = 0;
    var job: ae.Jobs.Job = .{ .context = &completed, .run = struct {
        fn run(context: *anyopaque) !void {
            const value: *u32 = @ptrCast(@alignCast(context));
            value.* += 1;
        }
    }.run };
    try executor.submit(&job);
    if (executor.mode == .threaded) try job.wait(init.io) else try job.result();
    if (completed != 1) return error.JobDidNotRun;
    if (ae.Util.PriorityScope.enter(.low)) |token| {
        var scope = token;
        try scope.restore();
    } else |err| switch (err) {
        error.UnsupportedPlatform => {},
        else => return err,
    }
}

fn thread_probe(counter: *std.atomic.Value(u32)) void {
    std.mem.doNotOptimizeAway(ae.Util.Thread.current_priority());
    counter.store(1, .release);
}

/// Requires native graphics to be initialized on PSP because preparation may
/// show the network configuration dialog. The caller supplies a live stream.
export fn aether_api_smoke_network(stream: *const std.Io.net.Stream, no_delay: bool) bool {
    var session = ae.Network.Session.prepare() catch return false;
    defer session.release();

    session.configure_stream(stream.*, .{ .no_delay = no_delay }) catch return false;
    return true;
}

/// Requires a live thread handle and runs on the thread whose scoped priority
/// will be restored. This probe is compiled but never invoked by main.
export fn aether_api_smoke_priority(thread: *const ae.Util.Thread) bool {
    thread.set_priority(.low) catch return false;
    var scope = ae.Util.PriorityScope.enter(.high) catch return false;
    scope.restore() catch return false;
    var relative = ae.Util.PriorityScope.enter_relative(-1) catch return false;
    relative.restore() catch return false;
    return true;
}

/// Requires a live writable/readable texture, a populated batch and an active
/// rendering context. The harness owns frame timing and render-state setup.
export fn aether_api_smoke_render(texture: *Rendering.Texture, batch: *Rendering.BillboardBatcher) bool {
    const source: Image.View = .{ .width = 1, .height = 1, .data = &.{ 255, 255, 255, 255 } };
    texture.copy_image_region(source, .{ .width = 1, .height = 1 }, 0, 0) catch return false;
    texture.copy_region(texture, .{ .width = 1, .height = 1 }, 0, 0) catch return false;
    const flipbook = Rendering.Flipbook.init(source, .{
        .frame_width = 1,
        .frame_height = 1,
        .frame_count = 1,
        .frames_per_second = 1,
    }) catch return false;
    flipbook.copy_to_texture(texture, source, 0, 0, 0) catch return false;
    texture.update() catch return false;
    batch.upload() catch return false;
    batch.draw();
    return true;
}

export fn aether_api_smoke_export() bool {
    ae.FileExport.download("api-smoke.bin", .{ .filename = "api-smoke.bin" }) catch return false;
    return true;
}

/// Compile-only I/O coverage. A harness must provide a disposable writable
/// directory containing resources.zip and initialize Audio before invoking it.
export fn aether_api_smoke_io(init: *const std.process.Init, dir: *const std.Io.Dir) bool {
    io_probe(init.*, dir.*) catch return false;
    return true;
}

fn io_probe(init: std.process.Init, dir: std.Io.Dir) !void {
    const Settings = struct { volume: u8 = 5 };
    var bytes: [128]u8 = undefined;
    _ = try ae.Storage.save_json(init.io, dir, "api-smoke.json", Settings{}, &bytes, .{});
    const parsed = try ae.Storage.load_json(Settings, init.gpa, init.io, dir, "api-smoke.json", 128);
    defer parsed.deinit();

    std.mem.doNotOptimizeAway(parsed.value);

    var directory: ae.Resources.DirectorySource = .{ .allocator = init.gpa, .io = init.io, .dir = dir };
    var file = try directory.source().open("api-smoke.json");
    defer file.close();

    _ = try file.reader.readSliceShort(&bytes);
    const archive = try ae.Util.Zip.init_options(init.gpa, init.io, dir, "resources.zip", .{ .max_streams = 2 });
    defer archive.deinit();

    const Store = ae.Resources.AssetStore(u8);
    const Loader = struct {
        fn load(_: ?*anyopaque, _: std.mem.Allocator, _: []const u8, reader: *std.Io.Reader) !u8 {
            return try reader.takeByte();
        }
        fn destroy(_: ?*anyopaque, _: std.mem.Allocator, _: *u8) void {}
    };
    var store = Store.init(init.gpa, .{ .load = Loader.load, .destroy = Loader.destroy }, 4);
    defer store.deinit();

    try store.apply(archive.source(), &.{"data.bin"});
    std.mem.doNotOptimizeAway(store.get("data.bin"));

    const stream = try ae.Audio.create_wav_stream(init.gpa, archive.source(), "audio.wav");
    errdefer ae.Audio.destroy_stream(stream);
    const voice = try ae.Audio.play_stream(stream, &.{});
    ae.Audio.stop(voice);
}
