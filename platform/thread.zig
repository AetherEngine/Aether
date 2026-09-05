//! Thread ownership and backend selection.
//! `Config.allocator` owns the console thread's closure until it returns.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");
const thread_api = @import("thread_api.zig");

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
