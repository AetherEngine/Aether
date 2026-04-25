//! Cross-platform thread abstraction.
//!
//! `spawn` mirrors `std.Thread.spawn(config, function, args)`. The `Config`
//! struct extends `std.Thread.SpawnConfig` with `name` and `priority` -- the
//! two PSP-only knobs that motivated this layer.
//!
//! On PSP, `Config.allocator` is **required**: it owns the trampoline
//! closure that lives until the thread function returns. On desktop the
//! allocator is forwarded to `std.Thread.spawn` and only consulted on
//! platforms that need to allocate a stack manually (e.g. WASI).

const std = @import("std");
const builtin = @import("builtin");
const platform_thread = @import("../platform/thread.zig");
const api = @import("../platform/thread_api.zig");

pub const Priority = api.Priority;
pub const Config = api.Config;

pub const Thread = struct {
    handle: platform_thread.Api.Handle,

    pub fn spawn(cfg: Config, comptime func: anytype, args: anytype) !Thread {
        const handle = try platform_thread.Api.spawn(cfg, func, args);
        return .{ .handle = handle };
    }

    pub fn join(self: Thread) void {
        platform_thread.Api.join(self.handle);
    }

    pub fn set_priority(self: Thread, p: Priority) !void {
        try platform_thread.Api.set_priority(self.handle, p);
    }

    /// Priority of the calling thread.
    pub fn current_priority() Priority {
        return platform_thread.Api.current_priority();
    }
};

// -----------------------------------------------------------------------------
// Tests (desktop only -- PSP has no `zig build test` target).
// -----------------------------------------------------------------------------

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

