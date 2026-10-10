//! Browser executable root. The page drives these exports; see
//! `platform/wasm/entry.zig`.
const std = @import("std");
const platform = @import("platform");
const app = @import("aether_app");

const web_entry = platform.entry.target;

pub const std_options = app.options.std_options;
pub const std_options_debug_threaded_io = std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();

/// The canvas size is read by the surface; the arguments are informational.
export fn aether_wasm_init(_: u32, _: u32) bool {
    return web_entry.start(app.call_main);
}

export fn aether_wasm_frame() bool {
    return web_entry.frame();
}

export fn aether_wasm_deinit() void {
    web_entry.stop();
}
