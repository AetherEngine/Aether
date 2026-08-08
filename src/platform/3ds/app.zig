const std = @import("std");
const zitrus = @import("zitrus");

const horizon = zitrus.horizon;
const Application = horizon.Init.Application;

var app_init_storage: Application = undefined;
var app_init: ?*const Application = null;
var new_3ds = false;
var stream_cache_bytes: usize = 512 * 1024;

pub fn setApplication(app: Application, is_new_3ds: bool, cache_bytes: usize) void {
    app_init_storage = app;
    app_init = &app_init_storage;
    new_3ds = is_new_3ds;
    stream_cache_bytes = cache_bytes;
}

pub fn clearApplication() void {
    app_init = null;
    new_3ds = false;
    stream_cache_bytes = 512 * 1024;
}

pub fn currentApplication() ?*const Application {
    return app_init;
}

/// Returns whether the running console is a New Nintendo 3DS-family system.
///
/// The result is detected once during Aether startup and is available without
/// opening a Horizon service or issuing IPC from application code.
pub fn is_new() bool {
    return new_3ds;
}

/// Total bytes reserved from the engine audio pool for the 3DS streaming
/// prefetch cache. This is copied from `Nintendo3dsOptions` before Engine
/// initialization, so the audio backend does not need to import user-root
/// options directly.
pub fn audio_stream_cache_bytes() usize {
    return stream_cache_bytes;
}

pub fn update(comptime suspend_cb: anytype, comptime resume_cb: fn () void) bool {
    const app = app_init orelse return true;

    while (app.pollEvent() catch |err| {
        std.log.err("3DS applet poll failed: {s}", .{@errorName(err)});
        return false;
    }) |event| switch (event) {
        .jump_home_rejected => {},
        .quit => return false,
        .jump_home => {
            const capture = suspend_cb() catch |err| {
                std.log.err("3DS HOME suspend failed: {s}", .{@errorName(err)});
                return true;
            };
            switch (app.app.jumpToHome(app.apt, .app, app.srv, capture, .none) catch |err| {
                std.log.err("3DS HOME jump failed: {s}", .{@errorName(err)});
                resume_cb();
                return true;
            }) {
                .resumed => resume_cb(),
                .jump_home => unreachable,
                .must_close => return false,
            }
        },
        .sleep => {
            _ = suspend_cb() catch |err| {
                std.log.err("3DS sleep suspend failed: {s}", .{@errorName(err)});
                return true;
            };
            while ((app.app.waitNotification(app.apt, .app, app.srv) catch |err| {
                std.log.err("3DS sleep wait failed: {s}", .{@errorName(err)});
                resume_cb();
                return false;
            }) != .sleep_wakeup) {}
            resume_cb();
        },
    };

    return true;
}
