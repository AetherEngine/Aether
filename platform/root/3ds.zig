//! 3DS executable root.
//!
//! Zitrus owns the real process entry and reads its options from
//! `@import("root")`; this root provides them and forwards the Horizon
//! application to the 3DS entry.

const std = @import("std");
const platform = @import("platform");
const app = @import("aether_app");
const zitrus = @import("zitrus");

const min_stack_size: u32 = 768 * 1024;

pub const zitrus_options: zitrus.Options = .{
    .stack_size = @max(min_stack_size, app.options.nintendo_3ds.stack_size),
};

pub const std_options = app.options.std_options;
pub const std_os_options = zitrus.std_os_options;
pub const panic = std.debug.FullPanic(zitrus.horizon.debug.defaultPanic);
pub const std_options_debug_threaded_io = null;
pub const std_options_debug_io: std.Io = zitrus.horizon.Io.debug_io;
pub const std_options_cwd = zitrus.horizon.Io.Dir.cwd;

pub fn main(init: zitrus.horizon.Init.Application) !void {
    return platform.entry.target.run(init, .{
        .audio_stream_cache_bytes = app.options.nintendo_3ds.audio_stream_cache_bytes,
    }, app.call_main);
}
