const std = @import("std");
const zitrus = @import("zitrus");

const horizon = zitrus.horizon;
const Application = horizon.Init.Application;

pub const Debug = @import("debug_impl.zig");

var app_init: ?*const Application = null;

pub fn setApplication(app: *const Application) void {
    app_init = app;
}

pub fn clearApplication(app: *const Application) void {
    if (app_init == app) app_init = null;
}

pub fn currentApplication() ?*const Application {
    return app_init;
}

pub fn update(comptime suspend_cb: fn () void, comptime resume_cb: fn () void) bool {
    const app = app_init orelse return true;

    while (app.pollEvent() catch |err| {
        std.log.err("3DS applet poll failed: {s}", .{@errorName(err)});
        return false;
    }) |event| switch (event) {
        .jump_home_rejected => {},
        .quit => return false,
        .jump_home => {
            const capture = app.gsp.sendImportDisplayCaptureInfo() catch |err| {
                std.log.err("3DS HOME capture failed: {s}", .{@errorName(err)});
                return true;
            };
            suspend_cb();
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
            suspend_cb();
            while ((app.app.waitNotification(app.apt, .app, app.srv) catch |err| {
                std.log.err("3DS sleep wait failed: {s}", .{@errorName(err)});
                return false;
            }) != .sleep_wakeup) {}
            resume_cb();
        },
    };

    return true;
}
