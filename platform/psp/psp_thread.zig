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

/// PSP user threads live in priority [0x08..0x77]; lower = higher priority.
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
    const Startup = struct {
        ready: std.atomic.Value(bool) = .init(false),
        err: ?anyerror = null,
    };
    var startup: Startup = .{};

    const Args = @TypeOf(args);
    const Instance = struct {
        fn_args: Args,
        allocator: std.mem.Allocator,
        io: ?std.Io,
        cwd: [1024]u8 = undefined,
        cwd_len: usize = 0,
        startup: ?*Startup,

        fn entry(_: usize, raw: ?*anyopaque) callconv(.c) c_int {
            // PSP gives the entry a pointer to the kernel-copied argument
            // bytes. Those bytes contain our heap Instance pointer, not the
            // Instance struct itself.
            const self: *@This() = @as(*const *@This(), @ptrCast(@alignCast(raw.?))).*;
            const a = self.allocator;
            const Ret = @typeInfo(@TypeOf(func)).@"fn".return_type.?;

            sdk.extra.fpu.setIEEE754();
            if (self.io != null) {
                // PSP keeps the native cwd per thread. Avoid setCurrentPath:
                // the SDK's standard I/O wrapper also writes shared cwd state.
                sdk.io.chdir(self.cwd[0..self.cwd_len :0]) catch |err| {
                    const state = self.startup.?;
                    state.err = err;
                    state.ready.store(true, .release);
                    // The spawning thread joins and frees this failed closure.
                    return -1;
                };
                self.startup.?.ready.store(true, .release);
            }
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
    inst.* = .{ .fn_args = args, .allocator = alloc, .io = cfg.io, .startup = if (cfg.io != null) &startup else null };
    if (cfg.io) |io| {
        inst.cwd_len = try std.process.currentPath(io, inst.cwd[0 .. inst.cwd.len - 1]);
        inst.cwd[inst.cwd_len] = 0;
    }

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
    if (cfg.io != null) {
        while (!startup.ready.load(.acquire)) sdk.kernel.delay_thread(100) catch {};
        if (startup.err) |err| {
            sdk.kernel.wait_thread_end(thid, null) catch {};
            return err;
        }
    }

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

pub fn change_current_priority(priority: api.Priority) anyerror!i32 {
    const previous = sdk.kernel.get_thread_current_priority();
    try sdk.kernel.change_thread_priority(sdk.kernel.get_thread_id(), priority_to_psp(priority));
    return previous;
}

pub fn change_current_priority_by(delta: i32) anyerror!i32 {
    const previous = sdk.kernel.get_thread_current_priority();
    const next = try api.relative_priority(previous, delta, 0x08, 0x77);
    try sdk.kernel.change_thread_priority(sdk.kernel.get_thread_id(), next);
    return previous;
}

pub fn restore_current_priority(token: i32) anyerror!void {
    if (token < 0x08 or token > 0x77) return error.InvalidPriority;
    try sdk.kernel.change_thread_priority(sdk.kernel.get_thread_id(), token);
}
