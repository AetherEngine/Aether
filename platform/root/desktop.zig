//! Desktop executable root.
const std = @import("std");
const platform = @import("platform");
const app = @import("aether_app");

pub const std_options = app.options.std_options;
pub const std_options_debug_threaded_io = std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();

pub fn main(init: std.process.Init) !void {
    return platform.entry.target.run(init, app.call_main);
}
