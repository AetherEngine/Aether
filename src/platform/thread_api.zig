//! Backend thread handles and scheduling capabilities.

const std = @import("std");
const builtin = @import("builtin");

pub const Priority = enum(i8) { lowest, low, normal, high, highest };

pub const default_stack_size: usize = switch (builtin.os.tag) {
    .psp, .@"3ds" => 16 * 1024,
    else => 1 * 1024 * 1024,
};

pub const Config = struct {
    /// Display name (PSP shows this in dev tools; ignored on desktop).
    /// Truncated to 31 chars on PSP.
    name: [:0]const u8 = "aether",
    /// Stack size in bytes. PSP rounds up to a multiple of 256.
    stack_size: usize = default_stack_size,
    /// Priority bucket. PSP applies natively. Desktop stores it in a
    /// thread-local so `current_priority()` round-trips, but does NOT change
    /// OS-level scheduling.
    priority: Priority = .normal,
    /// Required on PSP (used to allocate the trampoline closure). Desktop
    /// forwards it to `std.Thread.spawn`.
    allocator: ?std.mem.Allocator = null,
};

pub fn InterfaceType(comptime Backend: type) type {
    return struct {
        join: fn (Backend.Handle) void,
        set_priority: fn (Backend.Handle, Priority) anyerror!void,
        current_priority: fn () Priority,
    };
}

pub fn assert_impl(comptime Backend: type) void {
    if (!@hasDecl(Backend, "Handle")) {
        @compileError("thread backend " ++ @typeName(Backend) ++ " is missing decl: Handle");
    }

    @import("contract.zig").assert_impl("thread", Backend, InterfaceType(Backend));

    if (!@hasDecl(Backend, "spawn")) {
        @compileError("thread backend " ++ @typeName(Backend) ++ " is missing decl: spawn");
    }
    // Generic spawn cannot be a function field; type-check a call without running it.
    const dummy = struct {
        fn f() void {}
    }.f;
    const SpawnRet = @TypeOf(Backend.spawn(Config{}, dummy, .{}));
    const ti = @typeInfo(SpawnRet);
    if (ti != .error_union or ti.error_union.payload != Backend.Handle) {
        @compileError("thread backend " ++ @typeName(Backend) ++
            ".spawn must return E!Handle, got " ++ @typeName(SpawnRet));
    }
}
