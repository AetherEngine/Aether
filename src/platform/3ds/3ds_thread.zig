//! 3DS thread backend -- wraps libctru's `threadCreate`/`threadJoin`.

const std = @import("std");
const c = @import("../nintendo_c.zig").c;
const api = @import("../thread_api.zig");

pub const Handle = c.Thread;

fn priority_to_3ds(p: api.Priority) c_int {
    return switch (p) {
        .highest => 0x18,
        .high => 0x20,
        .normal => 0x30,
        .low => 0x38,
        .lowest => 0x3f,
    };
}

fn priority_from_3ds(v: c_int) api.Priority {
    if (v <= 0x18) return .highest;
    if (v <= 0x20) return .high;
    if (v <= 0x30) return .normal;
    if (v <= 0x38) return .low;
    return .lowest;
}

pub fn spawn(cfg: api.Config, comptime func: anytype, args: anytype) !Handle {
    const alloc = cfg.allocator orelse return error.AllocatorRequired;

    const Args = @TypeOf(args);
    const Instance = struct {
        fn_args: Args,
        allocator: std.mem.Allocator,

        fn entry(raw: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const a = self.allocator;
            const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;

            switch (@typeInfo(Ret)) {
                .void, .noreturn => @call(.auto, func, self.fn_args),
                .error_union => @call(.auto, func, self.fn_args) catch |e| {
                    std.log.err("aether thread errored: {s}", .{@errorName(e)});
                },
                else => @compileError("thread fn must return void, !void, or noreturn"),
            }
            a.destroy(self);
        }
    };

    const inst = try alloc.create(Instance);
    errdefer alloc.destroy(inst);
    inst.* = .{ .fn_args = args, .allocator = alloc };

    const thread = c.threadCreate(
        Instance.entry,
        inst,
        cfg.stack_size,
        priority_to_3ds(cfg.priority),
        -2,
        false,
    ) orelse return error.SystemResources;

    return thread;
}

pub fn join(thread: Handle) void {
    _ = c.threadJoin(thread, std.math.maxInt(u64));
    c.threadFree(thread);
}

pub fn set_priority(thread: Handle, p: api.Priority) anyerror!void {
    const handle = c.threadGetHandle(thread);
    if (c.svcSetThreadPriority(handle, priority_to_3ds(p)) != 0)
        return error.SystemResources;
}

pub fn current_priority() api.Priority {
    var p: c.s32 = priority_to_3ds(.normal);
    const current = c.threadGetCurrent() orelse return .normal;
    const handle = c.threadGetHandle(current);
    if (c.svcGetThreadPriority(&p, handle) != 0) return .normal;
    return priority_from_3ds(p);
}
