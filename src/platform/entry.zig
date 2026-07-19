//! Default Aether executable root for desktop-style targets.

const std = @import("std");
const entry = @import("aether_entry_common");

pub const std_options = entry.options.std_options;
pub const std_options_debug_threaded_io = std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();

pub fn main(init: std.process.Init) !void {
    try entry.callMain(init);
}
