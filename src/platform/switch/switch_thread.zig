//! Switch thread backend -- wraps libnx's `threadCreate`/`threadStart`.

const std = @import("std");
const c = @import("../nintendo_c.zig").switch_c;
const api = @import("../thread_api.zig");

const Header = struct {
    thread: c.Thread = undefined,
    allocator: std.mem.Allocator,
    destroy: *const fn (*Header) void,
};

pub const Handle = *Header;

fn priority_to_switch(p: api.Priority) c_int {
    return switch (p) {
        .highest => 0x20,
        .high => 0x28,
        .normal => 0x2C,
        .low => 0x30,
        .lowest => 0x3B,
    };
}

fn priority_from_switch(v: c_int) api.Priority {
    if (v <= 0x20) return .highest;
    if (v <= 0x28) return .high;
    if (v <= 0x2C) return .normal;
    if (v <= 0x30) return .low;
    return .lowest;
}

pub fn spawn(cfg: api.Config, comptime func: anytype, args: anytype) !Handle {
    const alloc = cfg.allocator orelse return error.AllocatorRequired;

    const Args = @TypeOf(args);
    const Instance = struct {
        header: Header,
        fn_args: Args,

        fn entry(raw: ?*anyopaque) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;

            switch (@typeInfo(Ret)) {
                .void, .noreturn => @call(.auto, func, self.fn_args),
                .error_union => @call(.auto, func, self.fn_args) catch |e| {
                    std.log.err("aether thread errored: {s}", .{@errorName(e)});
                },
                else => @compileError("thread fn must return void, !void, or noreturn"),
            }
        }

        fn destroy(header: *Header) void {
            const self: *@This() = @fieldParentPtr("header", header);
            header.allocator.destroy(self);
        }
    };

    const inst = try alloc.create(Instance);
    errdefer alloc.destroy(inst);
    inst.* = .{
        .header = .{ .allocator = alloc, .destroy = Instance.destroy },
        .fn_args = args,
    };

    if (c.threadCreate(
        &inst.header.thread,
        Instance.entry,
        inst,
        null,
        cfg.stack_size,
        priority_to_switch(cfg.priority),
        -2,
    ) != 0) return error.SystemResources;
    errdefer _ = c.threadClose(&inst.header.thread);

    if (c.threadStart(&inst.header.thread) != 0) return error.SystemResources;
    return &inst.header;
}

pub fn join(thread: Handle) void {
    _ = c.threadWaitForExit(&thread.thread);
    _ = c.threadClose(&thread.thread);
    thread.destroy(thread);
}

pub fn set_priority(thread: Handle, p: api.Priority) anyerror!void {
    if (c.svcSetThreadPriority(thread.thread.handle, @intCast(priority_to_switch(p))) != 0)
        return error.SystemResources;
}

pub fn current_priority() api.Priority {
    var p: c.s32 = priority_to_switch(.normal);
    if (c.svcGetThreadPriority(&p, c.threadGetCurHandle()) != 0) return .normal;
    return priority_from_switch(p);
}
