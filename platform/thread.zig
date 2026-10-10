//! Native thread contract, the selected thread backend, and scoped priorities.
//!
//! `Thread` (public as `Util.Thread`) runs on native threads on every target
//! except the browser, including 3DS, where the Io has no concurrency. Where a
//! target's base Io lacks concurrency, AetherIo spawns its tasks through this
//! backend too. `Config.allocator` owns the console thread's closure until it
//! returns.

const std = @import("std");
const builtin = @import("builtin");
const system = @import("system.zig");
const contract = @import("contract.zig");
const backend = @import("backend.zig");

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
        /// Give same-priority threads a turn on cooperative schedulers (3DS).
        /// A no-op where the native scheduler is preemptive.
        cooperative_yield: fn () void,
    };
}

/// Runs a spawned thread's function from a backend trampoline, logging an
/// error return instead of propagating it across the native thread boundary.
pub fn run_entry(comptime func: anytype, args: anytype) void {
    const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
    switch (@typeInfo(Ret)) {
        .void, .noreturn => @call(.auto, func, args),
        .error_union => @call(.auto, func, args) catch |err| {
            std.log.err("aether thread errored: {s}", .{@errorName(err)});
        },
        else => @compileError("thread fn must return void, !void, or noreturn"),
    }
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

pub const Api = backend.target.thread;

comptime {
    assert_impl(Api);
}

/// Restore on the same thread, in reverse nesting order. The token retains
/// the native priority exactly, including values between priority buckets.
/// Returns UnsupportedPlatform on desktop/browser backends, which do not
/// implement native scheduler priority changes.
pub const PriorityScope = struct {
    previous: ?i32,

    pub fn enter(priority: Priority) !PriorityScope {
        return .{ .previous = try Api.change_current_priority(priority) };
    }

    /// Add delta in native scheduler units, retaining the exact previous
    /// value. Negative deltas raise priority on PSP, 3DS, and Switch. Invalid
    /// ranges/overflow fail without changing priority; desktop/browser report
    /// UnsupportedPlatform, including for a zero delta.
    pub fn enter_relative(delta: i32) !PriorityScope {
        return .{ .previous = try Api.change_current_priority_by(delta) };
    }

    pub fn restore(self: *PriorityScope) !void {
        const previous = self.previous orelse return;
        try Api.restore_current_priority(previous);
        self.previous = null;
    }
};

pub const Thread = struct {
    handle: Api.Handle,

    pub fn spawn(cfg: Config, comptime func: anytype, args: anytype) !Thread {
        return .{ .handle = try Api.spawn(cfg, func, args) };
    }

    pub fn join(self: Thread) void {
        Api.join(self.handle);
    }

    pub fn set_priority(self: Thread, p: Priority) !void {
        try Api.set_priority(self.handle, p);
    }

    /// Priority of the calling thread.
    pub fn current_priority() Priority {
        return Api.current_priority();
    }
};

pub const cooperative_yield = Api.cooperative_yield;

test "spawn/join roundtrip" {
    if (builtin.os.tag == .psp) return error.SkipZigTest;
    var counter = std.atomic.Value(u32).init(0);
    const t = try Thread.spawn(.{ .allocator = std.testing.allocator }, struct {
        fn run(c: *std.atomic.Value(u32)) void {
            _ = c.fetchAdd(1, .seq_cst);
        }
    }.run, .{&counter});
    t.join();
    try std.testing.expectEqual(@as(u32, 1), counter.load(.seq_cst));
}

test "scoped priorities restore nested calling-thread priorities" {
    if (!system.info().native_thread_priority) {
        try std.testing.expectError(error.UnsupportedPlatform, PriorityScope.enter(.low));
        try std.testing.expectError(error.UnsupportedPlatform, PriorityScope.enter_relative(-10));
        try std.testing.expectError(error.UnsupportedPlatform, PriorityScope.enter_relative(0));
        return;
    }
    const original = Thread.current_priority();
    var outer = try PriorityScope.enter(.low);
    defer outer.restore() catch unreachable;

    var inner = try PriorityScope.enter(.highest);
    try std.testing.expectEqual(Priority.highest, Thread.current_priority());
    try inner.restore();
    try inner.restore();
    try std.testing.expectEqual(Priority.low, Thread.current_priority());
    try outer.restore();
    try std.testing.expectEqual(original, Thread.current_priority());
}

test "relative priority scopes retain exact values between priority buckets" {
    if (!system.info().native_thread_priority) return error.SkipZigTest;
    var base = try PriorityScope.enter(.normal);
    defer base.restore() catch unreachable;

    var first = try PriorityScope.enter_relative(1);
    defer first.restore() catch unreachable;

    var second = try PriorityScope.enter_relative(1);
    defer second.restore() catch unreachable;

    try std.testing.expectEqual(first.previous.? + 1, second.previous.?);
    const intermediate = second.previous.?;
    try second.restore();
    var observed = try PriorityScope.enter_relative(0);
    defer observed.restore() catch unreachable;

    try std.testing.expectEqual(intermediate, observed.previous.?);
    try std.testing.expectError(error.InvalidPriority, PriorityScope.enter_relative(std.math.maxInt(i32)));
}

test "current_priority defaults to normal on the calling thread" {
    if (builtin.os.tag == .psp) return error.SkipZigTest;
    try std.testing.expectEqual(Priority.normal, Thread.current_priority());
}

test "spawned thread sees its requested priority" {
    if (builtin.os.tag == .psp) return error.SkipZigTest;
    var seen = std.atomic.Value(i8).init(-1);
    const t = try Thread.spawn(
        .{ .allocator = std.testing.allocator, .priority = .high },
        struct {
            fn run(s: *std.atomic.Value(i8)) void {
                s.store(@backingInt(Thread.current_priority()), .seq_cst);
            }
        }.run,
        .{&seen},
    );
    t.join();
    try std.testing.expectEqual(@as(i8, @backingInt(Priority.high)), seen.load(.seq_cst));
}
