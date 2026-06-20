const std = @import("std");
const zitrus = @import("zitrus");

const horizon = zitrus.horizon;
const Application = horizon.Init.Application;

pub const Debug = @import("debug_impl.zig");

var app_init_storage: Application = undefined;
var app_init: ?*const Application = null;

pub fn setApplication(app: Application) void {
    app_init_storage = app;
    app_init = &app_init_storage;
}

pub fn clearApplication() void {
    app_init = null;
}

pub fn currentApplication() ?*const Application {
    return app_init;
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
