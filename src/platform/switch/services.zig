//! Switch system services / entry shim.
//!
//! Exports a C-callable `main` that hands control to the user's Zig
//! `main`. The allocator and baseline `std.Io` pieces of `std.process.Init`
//! are wired through newlib; deeper platform services remain TODO.
//!
//! libnx's switch.specs links with `--require-defined=main`, which
//! pulls a strong `main` from libnx's crt0 by default. We shadow it
//! with this Zig export — same name, weakness doesn't matter since
//! ld picks the first definition seen — to route the entry through
//! Aether instead of libnx's nnMain wrapper.

const process_init = @import("aether").CProcessInit;
const std = @import("std");

pub const os = struct {
    pub const PATH_MAX = 1024;
    pub const NAME_MAX = 255;
};

fn AppRoot() type {
    const root = @import("root");
    return if (@hasDecl(root, "main")) root else @import("aether_user_root");
}

pub const std_options = if (@hasDecl(AppRoot(), "std_options")) AppRoot().std_options else std.Options{};
pub const panic = if (@hasDecl(AppRoot(), "panic")) AppRoot().panic else std.debug.no_panic;
pub const std_options_debug_threaded_io = if (@hasDecl(AppRoot(), "std_options_debug_threaded_io")) AppRoot().std_options_debug_threaded_io else null;
pub const std_options_debug_io = if (@hasDecl(AppRoot(), "std_options_debug_io")) AppRoot().std_options_debug_io else std.Io.failing;
const app_std_options_cwd: ?fn () std.Io.Dir = if (@hasDecl(AppRoot(), "std_options_cwd")) AppRoot().std_options_cwd else null;
pub const std_options_cwd = app_std_options_cwd orelse @import("aether").Cio.cwd;

comptime {
    @export(&entry, .{ .name = "main" });
}

fn entry(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    const init = process_init.makeInit(.{ .vector = {} });
    AppRoot().main(init) catch return 1;
    return 0;
}
