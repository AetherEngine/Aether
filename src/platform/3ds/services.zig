//! 3DS system services / entry shim.
//!
//! Exports a C-callable `main` that hands control to the user's Zig
//! `main`. `Init` is currently `undefined` — invoking the engine on
//! hardware will crash on the first real allocation. The shim exists
//! so the engine call graph is reachable from `-ofmt=c` codegen and
//! so libctru integration has a clear landing pad: when libctru is
//! wired in, build a real `std.process.Init` here (libctru-backed
//! `ArenaAllocator`, an `Io` implementation talking to the FS / SOC
//! services, an `Environ.Map`) and pass it to `root.main`.
//!
//! Stack default: libctru's 32 KB is far too small for any std-using
//! Zig code path. We override `__stacksize__` (a `WEAK` symbol in
//! libctru) with a strong export. 1 MB is comfortable; bump if engine
//! frames grow.

const std = @import("std");

comptime {
    @export(&entry, .{ .name = "main" });
    @export(&stack_size, .{ .name = "__stacksize__" });
}

var stack_size: u32 = 1 * 1024 * 1024;

fn entry() callconv(.c) c_int {
    const init: std.process.Init = undefined;
    @import("root").main(init) catch return 1;
    return 0;
}
