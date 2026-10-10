//! PSP process entry. pspsdk's start code builds `std.process.Init` around
//! its kernel-backed Io; the application receives an AetherIo over it.
const std = @import("std");
const entry = @import("../entry.zig");

pub const hosts_frame_loop = false;

pub fn run(init: std.process.Init, app_main: entry.AppMain) anyerror!void {
    return entry.run_app(init, app_main);
}

pub fn poll() bool {
    return true;
}
