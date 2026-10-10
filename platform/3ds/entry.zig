//! 3DS process entry. Zitrus owns the process start and hands over a Horizon
//! application; this brings up storage, sockets, and model detection, then
//! runs the application with `std.process.Init` like every other target.
const std = @import("std");
const zitrus = @import("zitrus");
const entry = @import("../entry.zig");
const backend = @import("../backend.zig");
const gfx = @import("../gfx.zig");
const audio = @import("../audio.zig");
const app = @import("app.zig");
const network = @import("network.zig");

const horizon = zitrus.horizon;
const Application = horizon.Init.Application;
const log = std.log.scoped(.aether_3ds_entry);

pub const hosts_frame_loop = false;

pub const Options = struct {
    audio_stream_cache_bytes: usize,
};

pub fn run(init: Application, opts: Options, app_main: entry.AppMain) anyerror!void {
    const is_new_3ds = detect_and_configure_new_3ds(init.srv);

    app.set_application(init, is_new_3ds, opts.audio_stream_cache_bytes);
    defer app.clear_application();

    try horizon.Io.global.initStorage(init.srv, .fs, 0);
    defer horizon.Io.global.deinitFilesystem();

    network.start(init.srv, init.base.gpa) catch |err| {
        log.warn("3DS network init skipped: {s}", .{@errorName(err)});
    };
    defer network.stop();

    horizon.Io.global.mountSelfRomFs("romfs") catch {};
    horizon.Io.global.mountArchive("sdmc", .sdmc, .empty, &.{}) catch {};

    const linear_gpa = horizon.heap.linear_page_allocator;

    var arena = std.heap.ArenaAllocator.init(linear_gpa);
    defer arena.deinit();

    var environ_map = std.process.Environ.Map.init(linear_gpa);
    defer environ_map.deinit();

    const process_init: std.process.Init = .{
        .minimal = .{
            .environ = .empty,
            .args = if (std.process.Args.Vector == void)
                .{ .vector = {} }
            else
                .{ .vector = &.{} },
        },
        .arena = &arena,
        .gpa = linear_gpa,
        .io = init.base.io,
        .environ_map = &environ_map,
        .preopens = .empty,
    };

    return entry.run_app(process_init, app_main);
}

/// Handles HOME, sleep, and quit requests from the applet manager.
pub fn poll() bool {
    return app.update(suspend_for_applet, resume_from_applet);
}

const ScreenCapture = horizon.services.GraphicsServerGpu.ScreenCapture;

fn suspend_for_applet() anyerror!ScreenCapture {
    const capture = if (backend.native_video)
        try gfx.surface.suspend_for_applet()
    else blk: {
        const current = app.current_application() orelse return error.NoCurrentApplication;
        break :blk try current.gsp.sendImportDisplayCaptureInfo();
    };
    if (backend.native_audio) audio.Api.suspend_for_applet();
    return capture;
}

fn resume_from_applet() void {
    if (backend.native_video) gfx.surface.resume_from_applet();
    if (backend.native_audio) audio.Api.resume_from_applet();
}

/// Detects New Nintendo 3DS hardware and enables its higher CPU clock and L2
/// cache before the engine or application creates any platform resources.
///
/// Failure to query or configure PTM is deliberately non-fatal: applications
/// still run at the system-selected performance level, and `N3ds.is_new()`
/// reports false when the hardware probe itself could not complete.
fn detect_and_configure_new_3ds(srv: horizon.ServiceManager) bool {
    const Playtime = horizon.services.Playtime;
    const ptm = Playtime.open(srv, .system_menu) catch |err| {
        log.warn("3DS New-model detection skipped: {s}", .{@errorName(err)});
        return false;
    };
    defer ptm.close();

    const is_new_3ds = ptm.sendIsNew3ds() catch |err| {
        log.warn("3DS New-model detection failed: {s}", .{@errorName(err)});
        return false;
    };
    if (!is_new_3ds) return false;

    ptm.sendConfigureCpuCache(.{
        .@"804Mhz" = true,
        .l2 = true,
    }) catch |err| {
        log.warn("3DS New-model performance mode unavailable: {s}", .{@errorName(err)});
        return true;
    };

    log.info("3DS New-model performance mode enabled (804 MHz + L2 cache)", .{});
    return true;
}
