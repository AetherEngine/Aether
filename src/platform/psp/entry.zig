//! PSP executable root.
//!
//! pspsdk owns the real module entry and reads a few declarations from
//! `@import("root")`; this shim provides those declarations from
//! `aether_options` and forwards execution to the user's root.

const std = @import("std");
const entry = @import("aether_entry_common");
const sdk = @import("pspsdk");

comptime {
    const psp = entry.options.psp;
    const module_name = psp.module_name orelse entry.options.title;
    asm (sdk.extra.module.module_info(module_name, .{
            .mode = switch (psp.module_mode) {
                .user => .User,
                .kernel => .Kernel,
            },
        }, entry.options.version.major, entry.options.version.minor));
}

pub const std_options = entry.options.std_options;
pub const panic = sdk.extra.debug.panic;
pub const std_options_debug_threaded_io = null;
pub const std_options_debug_io: std.Io = sdk.extra.Io.psp_io;
pub const std_options_cwd = pspCwd;

pub const psp_stack_size: u32 = entry.options.psp.stack_size;
pub const psp_async_stack_size: u32 = entry.options.psp.async_stack_size;
pub const psp_heap_kb_size: u32 = entry.options.psp.heap_kb_size;
pub const psp_heap_reserve_kb_size: u32 = entry.options.psp.heap_reserve_kb_size;

pub fn main(init: std.process.Init) !void {
    try entry.callMain(init);
}

fn pspCwd() std.Io.Dir {
    return .{ .handle = -1 };
}
