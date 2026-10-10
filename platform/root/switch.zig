//! Switch executable root. Exports the C `main` libnx's crt0 calls; see
//! `platform/switch/entry.zig`.
const std = @import("std");
const platform = @import("platform");
const app = @import("aether_app");

const switch_entry = platform.entry.target;

pub const os = switch_entry.std_os;

pub const std_options = app.options.std_options;
pub const std_options_debug_threaded_io = null;
pub const std_options_debug_io: std.Io = switch_entry.debug_io;
pub const std_options_cwd = switch_entry.cwd;
pub const panic = switch_entry.panic;

comptime {
    @export(&c_main, .{ .name = "main" });
}

fn c_main(argc: c_int, argv: [*c][*c]u8) callconv(.c) c_int {
    return switch_entry.run(argc, argv, app.call_main);
}
