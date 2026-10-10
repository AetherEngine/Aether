//! PSP executable root.
//!
//! pspsdk owns the real module entry and reads a few declarations from
//! `@import("root")`; this root provides them from `aether_options` and
//! forwards execution to the PSP entry.

const std = @import("std");
const platform = @import("platform");
const app = @import("aether_app");
const sdk = @import("pspsdk");

comptime {
    const psp = app.options.psp;
    const module_name = psp.module_name orelse app.options.title;
    asm (sdk.extra.module.module_info(module_name, .{
            .mode = switch (psp.module_mode) {
                .user => .User,
                .kernel => .Kernel,
            },
        }, app.options.version.major, app.options.version.minor));
}

pub const std_options = app.options.std_options;
pub const panic = sdk.extra.debug.panic;
pub const std_options_debug_threaded_io = null;
pub const std_options_debug_io: std.Io = sdk.extra.Io.psp_io;
pub const std_options_cwd = psp_cwd;

pub const psp_stack_size: u32 = app.options.psp.stack_size;
pub const psp_async_stack_size: u32 = app.options.psp.async_stack_size;
pub const psp_heap_kb_size: u32 = app.options.psp.heap_kb_size;
pub const psp_heap_reserve_kb_size: u32 = app.options.psp.heap_reserve_kb_size;

pub fn main(init: std.process.Init) !void {
    return platform.entry.target.run(init, app.call_main);
}

fn psp_cwd() std.Io.Dir {
    return .{ .handle = -1 };
}
