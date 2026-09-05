//! 3DS thread backend -- delegates to Zitrus' std.Thread-compatible wrapper.

const std = @import("std");
const zitrus = @import("zitrus");
const api = @import("../thread_api.zig");
const app = @import("app.zig");

const horizon = zitrus.horizon;
const ThreadImpl = horizon.Thread.Impl;

pub const Handle = ThreadImpl;

threadlocal var current_prio: api.Priority = .normal;

fn priority_to_3ds(p: api.Priority) horizon.Thread.Priority {
    return .priority(switch (p) {
        .highest => 0x18,
        .high => 0x1A,
        .normal => 0x1C,
        .low => 0x24,
        .lowest => 0x30,
    });
}

fn priority_from_3ds(v: u6) api.Priority {
    if (v <= 0x18) return .highest;
    if (v <= 0x1A) return .high;
    if (v <= 0x1C) return .normal;
    if (v <= 0x24) return .low;
    return .lowest;
}

pub fn spawn(cfg: api.Config, comptime func: anytype, args: anytype) !Handle {
    _ = cfg.allocator;
    const thread_alloc = if (app.current_application()) |init|
        init.base.gpa
    else
        return error.NoCurrentApplication;

    const Args = @TypeOf(args);
    const Wrapped = struct {
        fn run(prio: api.Priority, fn_args: Args) void {
            current_prio = prio;
            const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
            switch (@typeInfo(Ret)) {
                .void, .noreturn => @call(.auto, func, fn_args),
                .error_union => @call(.auto, func, fn_args) catch |e| {
                    std.log.err("aether thread errored: {s}", .{@errorName(e)});
                },
                else => @compileError("thread fn must return void, !void, or noreturn"),
            }
        }
    };

    return try ThreadImpl.spawnOptions(
        .{ .stack_size = cfg.stack_size, .allocator = thread_alloc },
        Wrapped.run,
        .{ cfg.priority, args },
        .{ .priority = priority_to_3ds(cfg.priority), .processor = .any },
    );
}

pub fn join(thread: Handle) void {
    thread.join();
}

pub fn set_priority(thread: Handle, p: api.Priority) anyerror!void {
    const handle = ThreadImpl.getHandle(thread);
    const rc = horizon.setThreadPriority(handle, @intFromEnum(priority_to_3ds(p)));
    if (!rc.isSuccess()) return error.SystemResources;
    current_prio = p;
}

pub fn current_priority() api.Priority {
    return switch (horizon.getThreadPriority(.current).cases()) {
        .success => |s| blk: {
            current_prio = priority_from_3ds(s.value);
            break :blk current_prio;
        },
        .failure => current_prio,
    };
}

pub fn change_current_priority(priority: api.Priority) anyerror!i32 {
    const previous = switch (horizon.getThreadPriority(.current).cases()) {
        .success => |s| s.value,
        .failure => return error.SystemResources,
    };
    if (!horizon.setThreadPriority(.current, @intFromEnum(priority_to_3ds(priority))).isSuccess()) return error.SystemResources;
    return previous;
}

pub fn change_current_priority_by(delta: i32) anyerror!i32 {
    const previous = switch (horizon.getThreadPriority(.current).cases()) {
        .success => |s| s.value,
        .failure => return error.SystemResources,
    };
    const next = try api.relative_priority(previous, delta, 0, 63);
    if (!horizon.setThreadPriority(.current, @intCast(next)).isSuccess()) return error.SystemResources;
    return previous;
}

pub fn restore_current_priority(token: i32) anyerror!void {
    if (token < 0 or token > 63) return error.InvalidPriority;
    if (!horizon.setThreadPriority(.current, @intCast(token)).isSuccess()) return error.SystemResources;
}
