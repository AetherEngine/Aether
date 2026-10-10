//! AetherIo: the `std.Io` every Aether entry hands to the application.
//!
//! A target supplies a base `std.Io` (files, sockets, clocks, futexes). Where
//! that Io already implements `async`, `concurrent`, and groups (std.Io.Threaded
//! on desktop, pspsdk's Io, the browser's single-threaded Io, Zitrus' Horizon
//! Io), the application receives it unchanged, cancellation included. Where it
//! does not (Switch's newlib Io), AetherIo forwards every other operation and
//! runs tasks on the target's native threads (`<target>/thread.zig`). Those
//! tasks cannot be interrupted: `cancel` waits like `await`.
//!
//! Threads with explicit names, stacks, or priorities come from `Util.Thread`.

const std = @import("std");
const thread = @import("thread.zig");
const system = @import("system.zig");
const target_io = @import("backend.zig").target.io;

const Io = std.Io;
const Alignment = std.mem.Alignment;
const StartFuture = *const fn (context: *const anyopaque, result: *anyopaque) void;
const StartGroup = *const fn (context: *const anyopaque) void;

/// False where `std.Io.VTable` is not a runtime vtable AetherIo can wrap.
pub const interposes = @typeInfo(Io.VTable) == .@"struct";

/// Longest path, including the native terminator, the target's Io accepts.
pub const max_path_bytes: usize = target_io.max_path_bytes;

/// Rename over an existing file replaces it atomically.
pub const rename_replaces_destination: bool = target_io.rename_replaces_destination;

/// Where an Io's `async`, `concurrent`, and group tasks run.
pub const Tasks = union(enum) {
    /// The base Io implements them; AetherIo passes the base through.
    base,
    /// The base Io lacks them; AetherIo runs them on native threads.
    native_threads: struct { stack_size: usize },
};

pub const AetherIo = struct {
    base: Io,
    /// Thread-safe; owns task closures and native thread bookkeeping.
    gpa: std.mem.Allocator,
    tasks: Tasks,

    /// Uses the target's task source (`<target>/io.zig`).
    pub fn init(base: Io, gpa: std.mem.Allocator) AetherIo {
        return .{ .base = base, .gpa = gpa, .tasks = target_io.tasks };
    }

    /// The Io to hand out. Keep `self` alive and in place while it is used.
    pub fn io(self: *AetherIo) Io {
        if (comptime !interposes) return self.base;
        return switch (self.tasks) {
            .base => self.base,
            .native_threads => .{ .userdata = self, .vtable = &vtable },
        };
    }

    fn spawn(self: *AetherIo, task: *Task) bool {
        task.handle = thread.Api.spawn(.{
            .name = "aether_task",
            .stack_size = self.tasks.native_threads.stack_size,
            .priority = thread.Api.current_priority(),
            .allocator = self.gpa,
            // PSP keeps cwd per thread; let tasks inherit the caller's.
            .io = self.base,
        }, Task.run, .{task}) catch return false;
        return true;
    }
};

fn owner(userdata: ?*anyopaque) *AetherIo {
    return @ptrCast(@alignCast(userdata.?));
}

/// One heap block: the Task header, then the copied context, then the result.
const Task = struct {
    handle: thread.Api.Handle = undefined,
    gpa: std.mem.Allocator,
    alignment: Alignment,
    len: usize,
    context_offset: usize,
    result_offset: usize,
    result_len: usize,
    start: union(enum) { future: StartFuture, group: StartGroup },
    /// Next member of the owning group's pending list.
    next: ?*Task = null,

    fn create(
        gpa: std.mem.Allocator,
        context_bytes: []const u8,
        context_alignment: Alignment,
        result_len: usize,
        result_alignment: Alignment,
        start: @FieldType(Task, "start"),
    ) ?*Task {
        const alignment = Alignment.max(Alignment.of(Task), Alignment.max(context_alignment, result_alignment));
        const context_offset = context_alignment.forward(@sizeOf(Task));
        const result_offset = result_alignment.forward(context_offset + context_bytes.len);
        const len = result_offset + @max(result_len, 1);
        const memory = gpa.rawAlloc(len, alignment, @returnAddress()) orelse return null;
        const task: *Task = @ptrCast(@alignCast(memory));
        task.* = .{
            .gpa = gpa,
            .alignment = alignment,
            .len = len,
            .context_offset = context_offset,
            .result_offset = result_offset,
            .result_len = result_len,
            .start = start,
        };
        @memcpy(memory[context_offset..][0..context_bytes.len], context_bytes);
        return task;
    }

    fn destroy(task: *Task) void {
        const memory: [*]u8 = @ptrCast(task);
        task.gpa.rawFree(memory[0..task.len], task.alignment, @returnAddress());
    }

    fn context(task: *Task) *const anyopaque {
        const memory: [*]u8 = @ptrCast(task);
        return memory + task.context_offset;
    }

    fn result(task: *Task) []u8 {
        const memory: [*]u8 = @ptrCast(task);
        return memory[task.result_offset..][0..task.result_len];
    }

    fn run(task: *Task) void {
        switch (task.start) {
            .future => |start| start(task.context(), task.result().ptr),
            .group => |start| start(task.context()),
        }
    }

    fn join(task: *Task) void {
        thread.Api.join(task.handle);
    }
};

fn task_async(
    userdata: ?*anyopaque,
    result: []u8,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: StartFuture,
) ?*Io.AnyFuture {
    const future = task_concurrent(userdata, result.len, result_alignment, context, context_alignment, start) catch {
        start(context.ptr, result.ptr);
        return null;
    };
    return future;
}

fn task_concurrent(
    userdata: ?*anyopaque,
    result_len: usize,
    result_alignment: Alignment,
    context: []const u8,
    context_alignment: Alignment,
    start: StartFuture,
) Io.ConcurrentError!*Io.AnyFuture {
    const self = owner(userdata);
    const task = Task.create(self.gpa, context, context_alignment, result_len, result_alignment, .{ .future = start }) orelse
        return error.ConcurrencyUnavailable;
    if (!self.spawn(task)) {
        task.destroy();
        return error.ConcurrencyUnavailable;
    }
    return @ptrCast(task);
}

fn task_await(_: ?*anyopaque, any_future: *Io.AnyFuture, result: []u8, _: Alignment) void {
    const task: *Task = @ptrCast(@alignCast(any_future));
    task.join();
    @memcpy(result, task.result());
    task.destroy();
}

fn group_async(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: StartGroup,
) void {
    group_concurrent(userdata, group, context, context_alignment, start) catch start(context.ptr);
}

fn group_concurrent(
    userdata: ?*anyopaque,
    group: *Io.Group,
    context: []const u8,
    context_alignment: Alignment,
    start: StartGroup,
) Io.ConcurrentError!void {
    const self = owner(userdata);
    const task = Task.create(self.gpa, context, context_alignment, 0, .@"1", .{ .group = start }) orelse
        return error.ConcurrencyUnavailable;
    if (!self.spawn(task)) {
        task.destroy();
        return error.ConcurrencyUnavailable;
    }
    // Members may be added from several threads; push onto the token list.
    var head = group.token.load(.monotonic);
    while (true) {
        task.next = @ptrCast(@alignCast(head));
        head = group.token.cmpxchgWeak(head, task, .release, .monotonic) orelse return;
    }
}

fn group_await(_: ?*anyopaque, group: *Io.Group, _: *anyopaque) Io.Cancelable!void {
    join_group(group);
}

fn group_cancel(_: ?*anyopaque, group: *Io.Group, _: *anyopaque) void {
    join_group(group);
}

fn join_group(group: *Io.Group) void {
    var next: ?*Task = @ptrCast(@alignCast(group.token.swap(null, .acquire)));
    while (next) |task| {
        next = task.next;
        task.join();
        task.destroy();
    }
}

const vtable: if (interposes) Io.VTable else void = if (interposes) build_vtable() else {};

fn build_vtable() Io.VTable {
    @setEvalBranchQuota(20_000);
    var result: Io.VTable = undefined;
    for (std.meta.fieldNames(Io.VTable)) |name| {
        @field(result, name) = forward(name);
    }
    result.async = task_async;
    result.concurrent = task_concurrent;
    result.await = task_await;
    result.cancel = task_await;
    result.groupAsync = group_async;
    result.groupConcurrent = group_concurrent;
    result.groupAwait = group_await;
    result.groupCancel = group_cancel;
    return result;
}

/// A vtable entry that unwraps AetherIo and calls the base implementation.
fn forward(comptime name: []const u8) @FieldType(Io.VTable, name) {
    const info = @typeInfo(@typeInfo(@FieldType(Io.VTable, name)).pointer.child).@"fn";
    const R = info.return_type.?;
    const P = info.param_types;
    const Forward = struct {
        inline fn call(userdata: ?*anyopaque, args: anytype) R {
            const self = owner(userdata);
            return @call(.auto, @field(self.base.vtable, name), .{self.base.userdata} ++ args);
        }
    };
    return switch (P.len) {
        1 => &struct {
            fn f(u: ?*anyopaque) R {
                return Forward.call(u, .{});
            }
        }.f,
        2 => &struct {
            fn f(u: ?*anyopaque, a: P[1].?) R {
                return Forward.call(u, .{a});
            }
        }.f,
        3 => &struct {
            fn f(u: ?*anyopaque, a: P[1].?, b: P[2].?) R {
                return Forward.call(u, .{ a, b });
            }
        }.f,
        4 => &struct {
            fn f(u: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?) R {
                return Forward.call(u, .{ a, b, c });
            }
        }.f,
        5 => &struct {
            fn f(u: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?) R {
                return Forward.call(u, .{ a, b, c, d });
            }
        }.f,
        6 => &struct {
            fn f(u: ?*anyopaque, a: P[1].?, b: P[2].?, c: P[3].?, d: P[4].?, e: P[5].?) R {
                return Forward.call(u, .{ a, b, c, d, e });
            }
        }.f,
        7 => &struct {
            fn f(
                u: ?*anyopaque,
                a: P[1].?,
                b: P[2].?,
                c: P[3].?,
                d: P[4].?,
                e: P[5].?,
                g: P[6].?,
            ) R {
                return Forward.call(u, .{ a, b, c, d, e, g });
            }
        }.f,
        else => @compileError("AetherIo cannot forward std.Io.VTable." ++ name),
    };
}

fn native_threads_for_test(base: Io) AetherIo {
    return .{ .base = base, .gpa = std.testing.allocator, .tasks = .{ .native_threads = .{ .stack_size = 1024 * 1024 } } };
}

test "native-thread tasks run concurrently and return their results" {
    if (!interposes or !system.info().background_workers) return error.SkipZigTest;
    var aether = native_threads_for_test(std.testing.io);
    const io = aether.io();

    const Work = struct {
        fn square(value: u32) u32 {
            return value * value;
        }
    };
    var first = try io.concurrent(Work.square, .{7});
    var second = io.async(Work.square, .{9});
    try std.testing.expectEqual(@as(u32, 49), first.await(io));
    try std.testing.expectEqual(@as(u32, 81), second.cancel(io));
}

test "native-thread groups join every member and forwarded operations reach the base" {
    if (!interposes or !system.info().background_workers) return error.SkipZigTest;
    var aether = native_threads_for_test(std.testing.io);
    const io = aether.io();

    var counter = std.atomic.Value(u32).init(0);
    const Work = struct {
        fn bump(value: *std.atomic.Value(u32)) void {
            _ = value.fetchAdd(1, .acq_rel);
        }
    };
    var group: Io.Group = .init;
    for (0..4) |_| try group.concurrent(io, Work.bump, .{&counter});
    group.async(io, Work.bump, .{&counter});
    try group.await(io);
    try std.testing.expectEqual(@as(u32, 5), counter.load(.acquire));

    const before = Io.Clock.awake.now(io);
    try std.testing.expect(Io.Clock.awake.now(io).nanoseconds >= before.nanoseconds);
}

test "a base Io with its own concurrency passes through unchanged" {
    var aether: AetherIo = .{ .base = std.testing.io, .gpa = std.testing.allocator, .tasks = .base };
    const io = aether.io();
    try std.testing.expectEqual(std.testing.io.vtable, io.vtable);
}
