//! Desktop process entry. std's start code builds `std.process.Init` around
//! a std.Io.Threaded; the application receives an AetherIo over it.
const std = @import("std");
const entry = @import("../entry.zig");

pub const hosts_frame_loop = false;

pub fn run(init: std.process.Init, app_main: entry.AppMain) anyerror!void {
    return entry.run_app(init, app_main);
}

pub fn poll() bool {
    return true;
}
