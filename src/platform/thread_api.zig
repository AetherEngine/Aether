//! Contract every thread backend must satisfy.
//!
//! Backends differ only in their `Handle` type (a `std.Thread` on desktop, a
//! `sdk.SceUID` on PSP), so the interface is generic over `Backend`.
//!
//! `spawn` is intentionally omitted from the runtime interface struct since it
//! takes `comptime func: anytype, args: anytype` and cannot be expressed as a
//! function value. Its shape is still asserted at comptime by synthesizing a
//! call with a dummy zero-arg function and inspecting the return type via
//! `@TypeOf` -- `@TypeOf` type-checks the call without executing it.

const std = @import("std");
const builtin = @import("builtin");

pub const Priority = enum(i8) { lowest, low, normal, high, highest };

/// PSP RAM is precious so we keep the default tight; desktop pthreads need
/// room for TLS and guard pages, so we hand them something more conservative.
pub const default_stack_size: usize = if (builtin.os.tag == .psp) 16 * 1024 else 1 * 1024 * 1024;

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
    /// forwards it to `std.Thread.spawn`, which only consults it on platforms
    /// that need to allocate a stack manually (e.g. WASI).
    allocator: ?std.mem.Allocator = null,
};

pub fn Interface(comptime Backend: type) type {
    return struct {
        join: fn (Backend.Handle) void,
        set_priority: fn (Backend.Handle, Priority) anyerror!void,
        current_priority: fn () Priority,
    };
}

/// Verify at comptime that `Backend` exposes every decl required by the
/// interface, plus a `spawn` with the right shape. `@compileError`s with a
/// clear message on drift.
pub fn assert_impl(comptime Backend: type) void {
    if (!@hasDecl(Backend, "Handle")) {
        @compileError("thread backend " ++ @typeName(Backend) ++ " is missing decl: Handle");
    }

    const I = Interface(Backend);
    inline for (std.meta.fields(I)) |f| {
        if (!@hasDecl(Backend, f.name)) {
            @compileError("thread backend " ++ @typeName(Backend) ++ " is missing decl: " ++ f.name);
        }
        const Actual = @TypeOf(@field(Backend, f.name));
        if (Actual != f.type) {
            @compileError("thread backend " ++ @typeName(Backend) ++ "." ++ f.name ++
                " has type " ++ @typeName(Actual) ++ ", expected " ++ @typeName(f.type));
        }
    }

    if (!@hasDecl(Backend, "spawn")) {
        @compileError("thread backend " ++ @typeName(Backend) ++ " is missing decl: spawn");
    }
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
