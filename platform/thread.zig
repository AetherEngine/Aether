//! Thread ownership and backend selection.
//! `Config.allocator` owns the console thread's closure until it returns.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const thread_api = @import("thread_api.zig");
const system = @import("system.zig");

pub const Api = switch (options.config.platform) {
    .psp => @import("psp/psp_thread.zig"),
    .nintendo_3ds => @import("3ds/thread.zig"),
    .nintendo_switch => @import("switch/switch_thread.zig"),
    .wasm => @import("wasm/wasm_thread.zig"),
    else => @import("std_thread.zig"),
};

comptime {
    thread_api.assert_impl(Api);
}

pub const Priority = thread_api.Priority;
pub const Config = thread_api.Config;

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
                s.store(@intFromEnum(Thread.current_priority()), .seq_cst);
            }
        }.run,
        .{&seen},
    );
    t.join();
    try std.testing.expectEqual(@as(i8, @intFromEnum(Priority.high)), seen.load(.seq_cst));
}
