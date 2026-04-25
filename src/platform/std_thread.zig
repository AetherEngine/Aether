//! Desktop thread backend - wraps `std.Thread`.
//!
//! Priority has no OS-level effect here: setting it stores the value in a
//! `threadlocal` so `current_priority()` returns whatever was last requested
//! on the calling thread. The main thread (where nothing was set) reads back
//! `.normal` because that's the type's zero-value.

const std = @import("std");
const api = @import("thread_api.zig");

pub const Handle = std.Thread;

threadlocal var current_prio: api.Priority = .normal;

pub fn spawn(cfg: api.Config, comptime func: anytype, args: anytype) !Handle {
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

    return try std.Thread.spawn(
        .{ .stack_size = cfg.stack_size, .allocator = cfg.allocator },
        Wrapped.run,
        .{ cfg.priority, args },
    );
}

pub fn join(t: Handle) void {
    t.join();
}

pub fn set_priority(_: Handle, p: api.Priority) anyerror!void {
    // No OS-level effect on desktop. Store on the *calling* thread's TLS so
    // that calling `set_priority` then `current_priority` from the same
    // thread round-trips. Cross-thread set is therefore a no-op -- that's the
    // documented behavior.
    current_prio = p;
}

pub fn current_priority() api.Priority {
    return current_prio;
}
