//! Switch system services / entry shim.
//!
//! Exports a C-callable `main` that hands control to the user's Zig
//! `main`. `Init` is currently `undefined` — invoking the engine on
//! hardware will crash on the first real allocation. The shim exists
//! so the engine call graph is reachable from `-ofmt=c` codegen and
//! so libnx integration has a clear landing pad: when libnx is wired
//! in, build a real `std.process.Init` here (libnx-backed allocator,
//! an `Io` implementation talking to fs:srv / sockets, an
//! `Environ.Map`) and pass it to `root.main`.
//!
//! libnx's switch.specs links with `--require-defined=main`, which
//! pulls a strong `main` from libnx's crt0 by default. We shadow it
//! with this Zig export — same name, weakness doesn't matter since
//! ld picks the first definition seen — to route the entry through
//! Aether instead of libnx's nnMain wrapper.

const std = @import("std");

comptime {
    @export(&entry, .{ .name = "main" });
}

fn entry(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    const init: std.process.Init = undefined;
    @import("root").main(init) catch return 1;
    return 0;
}
