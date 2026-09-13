//! Backend thread handles and scheduling capabilities.

const std = @import("std");
const builtin = @import("builtin");
const contract = @import("contract.zig");

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
    /// Supply I/O to inherit the caller's cwd on PSP. Other targets inherit
    /// their process directory normally. This value must outlive the thread.
    io: ?std.Io = null,
};

pub fn InterfaceType(comptime Backend: type) type {
    return struct {
        join: fn (Backend.Handle) void,
        set_priority: fn (Backend.Handle, Priority) anyerror!void,
        current_priority: fn () Priority,
        change_current_priority: fn (Priority) anyerror!i32,
        change_current_priority_by: fn (i32) anyerror!i32,
        restore_current_priority: fn (i32) anyerror!void,
    };
}

/// Native priority arithmetic shared by backends. Never clamp a requested
/// change: an invalid delta must leave the calling thread unchanged.
pub fn relative_priority(previous: i32, delta: i32, minimum: i32, maximum: i32) error{InvalidPriority}!i32 {
    if (previous < minimum or previous > maximum) return error.InvalidPriority;
    const next = std.math.add(i32, previous, delta) catch return error.InvalidPriority;
    if (next < minimum or next > maximum) return error.InvalidPriority;
    return next;
}

test "relative thread priority preserves native values and rejects range and overflow" {
    try std.testing.expectEqual(@as(i32, 0x16), try relative_priority(0x20, -10, 0x08, 0x77));
    try std.testing.expectEqual(@as(i32, 0x08), try relative_priority(0x12, -10, 0x08, 0x77));
    try std.testing.expectEqual(@as(i32, 0x77), try relative_priority(0x76, 1, 0x08, 0x77));
    try std.testing.expectEqual(@as(i32, 0), try relative_priority(1, -1, 0, 63));
    try std.testing.expectEqual(@as(i32, 63), try relative_priority(62, 1, 0, 63));
    try std.testing.expectError(error.InvalidPriority, relative_priority(0x08, -1, 0x08, 0x77));
    try std.testing.expectError(error.InvalidPriority, relative_priority(0x77, 1, 0x08, 0x77));
    try std.testing.expectError(error.InvalidPriority, relative_priority(0, -1, 0, 63));
    try std.testing.expectError(error.InvalidPriority, relative_priority(63, 1, 0, 63));
    try std.testing.expectError(error.InvalidPriority, relative_priority(64, -1, 0, 63));
    try std.testing.expectError(error.InvalidPriority, relative_priority(63, std.math.maxInt(i32), 0, 63));
    try std.testing.expectError(error.InvalidPriority, relative_priority(1, std.math.minInt(i32), 0, 63));
}

pub fn assert_impl(comptime Backend: type) void {
    if (!@hasDecl(Backend, "Handle")) {
        @compileError("thread backend " ++ @typeName(Backend) ++ " is missing decl: Handle");
    }

    contract.assert_impl("thread", Backend, InterfaceType(Backend));

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
