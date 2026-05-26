//! 3DS system services / entry shim.
//!
//! Exports a C-callable `main` that hands control to the user's Zig
//! `main`. The allocator and baseline `std.Io` pieces of `std.process.Init`
//! are wired through newlib; deeper platform services remain TODO.
//!
//! Stack default: libctru's 32 KB is far too small for any std-using
//! Zig code path. We override `__stacksize__` (a `WEAK` symbol in
//! libctru) with a strong export. 1 MB is comfortable; bump if engine
//! frames grow.

const process_init = @import("../c_process_init.zig");

const argv = [_][*:0]const u8{"Aether"};

comptime {
    @export(&entry, .{ .name = "main" });
    @export(&stack_size, .{ .name = "__stacksize__" });
}

var stack_size: u32 = 1 * 1024 * 1024;

fn entry() callconv(.c) c_int {
    const init = process_init.makeInit(.{ .vector = &argv });
    @import("root").main(init) catch return 1;
    return 0;
}
