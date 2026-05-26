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

const process_init = @import("../c_process_init.zig");

comptime {
    @export(&entry, .{ .name = "main" });
}

fn entry(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    const init = process_init.makeInit(.{ .vector = {} });
    @import("root").main(init) catch return 1;
    return 0;
}
