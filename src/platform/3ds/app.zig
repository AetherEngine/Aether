const std = @import("std");
const zitrus = @import("zitrus");

const horizon = zitrus.horizon;
const Application = horizon.Init.Application;

var app_init: ?*const Application = null;

pub fn setApplication(app: *const Application) void {
    app_init = app;
}

pub fn clearApplication(app: *const Application) void {
    if (app_init == app) app_init = null;
}

pub fn update() bool {
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
            switch (app.app.jumpToHome(app.apt, .app, app.srv, capture, .none) catch |err| {
                std.log.err("3DS HOME jump failed: {s}", .{@errorName(err)});
                return true;
            }) {
                .resumed => {},
                .jump_home => unreachable,
                .must_close => return false,
            }
        },
        .sleep => {
            while ((app.app.waitNotification(app.apt, .app, app.srv) catch |err| {
                std.log.err("3DS sleep wait failed: {s}", .{@errorName(err)});
                return false;
            }) != .sleep_wakeup) {}
        },
    };

    return true;
}
