//! PSP thread backend -- wraps `sdk.kernel` thread APIs.
//!
//! Closure lifetime: `sceKernelStartThread` copies `arglen` bytes from the
//! supplied argument pointer into a kernel-owned buffer. Pass a pointer to
//! the heap `Instance` so the trampoline receives the complete pointer value
//! while the instance itself remains alive until the worker returns.
//!
//! The trampoline returns normally rather than calling `exit_delete_thread`
//! so that `wait_thread_end` + `delete_thread` from `join` succeed cleanly,
//! matching the pattern already in `psp_audio.zig`.

const std = @import("std");
const sdk = @import("pspsdk");
const api = @import("../thread_api.zig");

pub const Handle = sdk.SceUID;

/// PSP user threads live in priority [0x02..0x6F]; lower = higher priority.
/// The audio thread sits at 0x12, so `.normal` matches it.
fn priority_to_psp(p: api.Priority) i32 {
    return switch (p) {
        .highest => 0x08,
        .high => 0x10,
        .normal => 0x12,
        .low => 0x20,
        .lowest => 0x40,
    };
}

fn priority_from_psp(v: i32) api.Priority {
    if (v < 0x10) return .highest;
    if (v <= 0x12) return .high;
    if (v <= 0x1F) return .normal;
    if (v <= 0x3F) return .low;
    return .lowest;
}

pub fn spawn(cfg: api.Config, comptime func: anytype, args: anytype) !Handle {
    const alloc = cfg.allocator orelse return error.AllocatorRequired;

    const Args = @TypeOf(args);
    const Instance = struct {
        fn_args: Args,
        allocator: std.mem.Allocator,

        fn entry(_: usize, raw: ?*anyopaque) callconv(.c) c_int {
            // PSP gives the entry a pointer to the kernel-copied argument
            // bytes. Those bytes contain our heap Instance pointer, not the
            // Instance struct itself.
            const self: *@This() = @as(*const *@This(), @ptrCast(@alignCast(raw.?))).*;
            const a = self.allocator;
            const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;

            sdk.extra.fpu.setIEEE754();
            switch (@typeInfo(Ret)) {
                .void, .noreturn => @call(.auto, func, self.fn_args),
                .error_union => @call(.auto, func, self.fn_args) catch |e| {
                    std.log.err("aether thread errored: {s}", .{@errorName(e)});
                },
                else => @compileError("thread fn must return void, !void, or noreturn"),
            }
            a.destroy(self);
            return 0;
        }
    };

    const inst = try alloc.create(Instance);
    errdefer alloc.destroy(inst);
    inst.* = .{ .fn_args = args, .allocator = alloc };

    const stack_size: i32 = if (cfg.stack_size > std.math.maxInt(i32))
        std.math.maxInt(i32)
    else
        @intCast(cfg.stack_size);

    const thid = sdk.kernel.create_thread(
        cfg.name,
        Instance.entry,
        priority_to_psp(cfg.priority),
        stack_size,
        .{ .user = true },
        null,
    ) catch return error.SystemResources;
    errdefer sdk.kernel.delete_thread(thid) catch {};

    var arg: *Instance = inst;
    sdk.kernel.start_thread(thid, @sizeOf(@TypeOf(arg)), @ptrCast(&arg)) catch
        return error.SystemResources;

    return thid;
}

pub fn join(thid: Handle) void {
    sdk.kernel.wait_thread_end(thid, null) catch {};
    sdk.kernel.delete_thread(thid) catch {};
}

pub fn set_priority(thid: Handle, p: api.Priority) anyerror!void {
    try sdk.kernel.change_thread_priority(thid, priority_to_psp(p));
}

pub fn current_priority() api.Priority {
    return priority_from_psp(sdk.kernel.get_thread_current_priority());
}
