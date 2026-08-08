//! Nintendo 3DS asynchronous file logger.
//!
//! Filesystem operations on 3DS can block on an ARM11 <-> ARM9 IPC round
//! trip. This module keeps those operations on a low-priority `Util.Thread`
//! worker and never holds the producer queue mutex while it performs I/O.

const std = @import("std");
const options = @import("options");
const Thread = @import("thread.zig").Thread;

const message_capacity = 1024;
const queue_capacity = 32;
const bootstrap_capacity = 4;

const Lifecycle = enum(u8) {
    /// Console-entry diagnostics received before Engine.init.
    bootstrap,
    /// The worker is opening aether.log; producers may already enqueue.
    starting,
    /// The worker owns file and debug-output operations.
    running,
    /// Engine shutdown requested; queued messages are drained first.
    stopping,
    stopped,
    failed,
};

const LogMessage = struct {
    len: u16,
    bytes: [message_capacity]u8,

    fn slice(self: *const LogMessage) []const u8 {
        return self.bytes[0..self.len];
    }
};

const MessageQueue = struct {
    entries: [queue_capacity]LogMessage = undefined,
    read_index: usize = 0,
    len: usize = 0,

    fn reset(self: *MessageQueue) void {
        self.read_index = 0;
        self.len = 0;
    }

    fn push(self: *MessageQueue, message: LogMessage) bool {
        if (self.len == self.entries.len) return false;

        const write_index = (self.read_index + self.len) % self.entries.len;
        self.entries[write_index] = message;
        self.len += 1;
        return true;
    }

    fn pop(self: *MessageQueue) ?LogMessage {
        if (self.len == 0) return null;

        const message = self.entries[self.read_index];
        self.read_index = (self.read_index + 1) % self.entries.len;
        self.len -= 1;
        return message;
    }
};

var lifecycle: std.atomic.Value(Lifecycle) = .init(.bootstrap);
var log_io: std.Io = undefined;
var log_data_dir: std.Io.Dir = undefined;
var logger_thread: ?Thread = null;

var queue_mutex: std.Io.Mutex = .init;
var queue_wakeup: std.Io.Event = .unset;
var startup_complete: std.Io.Event = .unset;
var queue: MessageQueue = .{};
var flush_requested = false;
var dropped_messages: std.atomic.Value(usize) = .init(0);
var startup_error: ?std.Io.File.OpenError = null;

// Early logging can happen before an Io implementation is available. Each
// producer reserves a complete slot atomically, so this path has neither a
// spin lock nor an Io synchronization dependency. The worker waits for every
// in-flight bootstrap writer before it reads the slots.
var bootstrap_queue: [bootstrap_capacity]LogMessage = undefined;
var bootstrap_count: std.atomic.Value(usize) = .init(0);
var bootstrap_writers: std.atomic.Value(u32) = .init(0);
var bootstrap_truncated: std.atomic.Value(bool) = .init(false);

pub const Error = std.Io.File.OpenError || error{
    AlreadyInitialized,
    OutOfMemory,
    ThreadStartFailed,
};

/// Starts the logger worker. Startup waits for the worker to report file-open
/// errors so Engine.init retains its existing error behavior, but the actual
/// filesystem operation runs on the worker.
pub fn init(io: std.Io, data_dir: std.Io.Dir, allocator: std.mem.Allocator) Error!void {
    if (lifecycle.load(.acquire) != .bootstrap) return error.AlreadyInitialized;

    // Publish these before making `.starting` visible. A producer racing this
    // transition either completes a bootstrap slot or uses this Io to enqueue.
    log_io = io;
    log_data_dir = data_dir;
    queue.reset();
    flush_requested = false;
    dropped_messages.store(0, .release);
    startup_error = null;
    queue_wakeup.reset();
    startup_complete.reset();
    lifecycle.store(.starting, .release);

    logger_thread = Thread.spawn(
        .{
            .allocator = allocator,
            .name = "aether_logger",
            .priority = .lowest,
        },
        logger_thread_main,
        .{},
    ) catch |err| {
        lifecycle.store(.failed, .release);
        if (err == error.OutOfMemory) return error.OutOfMemory;
        return error.ThreadStartFailed;
    };

    startup_complete.waitUncancelable(io);
    switch (lifecycle.load(.acquire)) {
        .running => {},
        .failed => {
            if (logger_thread) |thread| thread.join();
            logger_thread = null;
            return startup_error orelse error.ThreadStartFailed;
        },
        else => unreachable,
    }
}

pub fn deinit(_: std.Io) void {
    switch (lifecycle.load(.acquire)) {
        .starting, .running => {
            // Shutdown may wait briefly for an in-memory producer. Runtime
            // logging uses tryLock and cannot block an audio or game thread.
            queue_mutex.lockUncancelable(log_io);
            lifecycle.store(.stopping, .release);
            queue_wakeup.set(log_io);
            queue_mutex.unlock(log_io);

            if (logger_thread) |thread| thread.join();
            logger_thread = null;
        },
        else => {},
    }
}

/// Requests a worker-side flush; callers never perform file I/O themselves.
pub fn flush() void {
    const state = lifecycle.load(.acquire);
    if (state != .starting and state != .running) return;
    if (!queue_mutex.tryLock()) return;
    defer queue_mutex.unlock(log_io);

    const locked_state = lifecycle.load(.acquire);
    if (locked_state != .starting and locked_state != .running) return;

    flush_requested = true;
    queue_wakeup.set(log_io);
}

pub fn aether_log_fn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const scope_prefix = "(" ++ @tagName(scope) ++ ") ";
    const prefix = scope_prefix ++ "[" ++ comptime level.asText() ++ "]: ";
    const message = format_message(prefix, format, args);

    switch (lifecycle.load(.acquire)) {
        .bootstrap => {
            if (append_bootstrap(message)) return;
            enqueue(message);
        },
        .starting, .running => enqueue(message),
        .stopping, .stopped, .failed => {},
    }
}

fn format_message(
    comptime prefix: []const u8,
    comptime format: []const u8,
    args: anytype,
) LogMessage {
    var message: LogMessage = .{
        .len = 0,
        .bytes = undefined,
    };
    const rendered = std.fmt.bufPrint(&message.bytes, prefix ++ format ++ "\n", args) catch {
        const fallback = "(logger) [warning]: log message was too long and was dropped\n";
        @memcpy(message.bytes[0..fallback.len], fallback);
        message.len = fallback.len;
        return message;
    };
    message.len = @intCast(rendered.len);
    return message;
}

/// Returns false only when init leaves bootstrap mode while this log call is
/// racing it. The caller then retries through the regular queue.
fn append_bootstrap(message: LogMessage) bool {
    if (lifecycle.load(.seq_cst) != .bootstrap) return false;

    _ = bootstrap_writers.fetchAdd(1, .seq_cst);
    if (lifecycle.load(.seq_cst) != .bootstrap) {
        finish_bootstrap_write();
        return false;
    }
    defer finish_bootstrap_write();

    const slot = bootstrap_count.fetchAdd(1, .seq_cst);
    if (slot >= bootstrap_queue.len) {
        bootstrap_truncated.store(true, .release);
        return true;
    }
    bootstrap_queue[slot] = message;
    return true;
}

fn finish_bootstrap_write() void {
    const prior = bootstrap_writers.fetchSub(1, .release);
    std.debug.assert(prior > 0);

    if (prior == 1 and lifecycle.load(.acquire) != .bootstrap) {
        log_io.futexWake(u32, &bootstrap_writers.raw, 1);
    }
}

fn wait_for_bootstrap_writers(io: std.Io) void {
    var writers = bootstrap_writers.load(.acquire);
    while (writers != 0) {
        io.futexWaitUncancelable(u32, &bootstrap_writers.raw, writers);
        writers = bootstrap_writers.load(.acquire);
    }
}

/// A log call must never block the main or audio thread. If the queue is busy
/// or full, retain the frame budget and let the worker report the dropped count.
fn enqueue(message: LogMessage) void {
    if (!queue_mutex.tryLock()) {
        _ = dropped_messages.fetchAdd(1, .monotonic);
        return;
    }
    defer queue_mutex.unlock(log_io);

    const state = lifecycle.load(.acquire);
    if (state != .starting and state != .running) return;

    if (!queue.push(message)) {
        _ = dropped_messages.fetchAdd(1, .monotonic);
        return;
    }
    queue_wakeup.set(log_io);
}

fn logger_thread_main() void {
    const io = log_io;
    wait_for_bootstrap_writers(io);

    const file = log_data_dir.createFile(io, "aether.log", .{ .truncate = true }) catch |err| {
        startup_error = err;
        lifecycle.store(.failed, .release);
        write_bootstrap_to_debug();
        drain_queue_to_debug(io);
        startup_complete.set(io);
        return;
    };

    var file_writer = file.writer(io, &worker_log_buffer);
    const writer = &file_writer.interface;
    flush_bootstrap_to_file(file, io, writer);

    lifecycle.store(.running, .release);
    startup_complete.set(io);

    logger_worker_loop(file, io, writer);
}

var worker_log_buffer: [4096]u8 = undefined;

fn logger_worker_loop(file: std.Io.File, io: std.Io, writer: *std.Io.Writer) void {
    while (true) {
        var message: ?LogMessage = null;
        var should_flush = false;

        queue_mutex.lockUncancelable(io);
        if (queue.pop()) |queued| {
            message = queued;
        } else if (flush_requested) {
            flush_requested = false;
            should_flush = true;
        } else if (lifecycle.load(.acquire) == .stopping) {
            queue_mutex.unlock(io);
            break;
        } else {
            // Producers enqueue only while holding this mutex. Resetting the
            // event here cannot erase a wakeup for a queued message: a racing
            // producer either sets it after unlock or drops its message.
            queue_wakeup.reset();
            queue_mutex.unlock(io);
            queue_wakeup.waitUncancelable(io);
            continue;
        }
        queue_mutex.unlock(io);

        if (message) |*queued| write_message(file, io, writer, queued);
        if (should_flush) flush_file(file, io, writer, true);
        write_dropped_warning(file, io, writer);
    }

    write_dropped_warning(file, io, writer);
    flush_file(file, io, writer, true);
    file.close(io);
    lifecycle.store(.stopped, .release);
}

fn flush_bootstrap_to_file(file: std.Io.File, io: std.Io, writer: *std.Io.Writer) void {
    const count = @min(bootstrap_count.load(.acquire), bootstrap_queue.len);
    for (bootstrap_queue[0..count]) |*message| {
        write_message(file, io, writer, message);
    }
    if (bootstrap_truncated.load(.acquire)) {
        write_raw(file, io, writer, "(logger) [warning]: early log messages were truncated\n");
    }
}

fn write_bootstrap_to_debug() void {
    const count = @min(bootstrap_count.load(.acquire), bootstrap_queue.len);
    for (bootstrap_queue[0..count]) |*message| {
        std.debug.print("{s}", .{message.slice()});
    }
    if (bootstrap_truncated.load(.acquire)) {
        std.debug.print("(logger) [warning]: early log messages were truncated\n", .{});
    }
}

fn drain_queue_to_debug(io: std.Io) void {
    while (true) {
        queue_mutex.lockUncancelable(io);
        const message = queue.pop();
        queue_mutex.unlock(io);

        if (message) |queued| {
            std.debug.print("{s}", .{queued.slice()});
        } else {
            break;
        }
    }
}

fn write_dropped_warning(file: std.Io.File, io: std.Io, writer: *std.Io.Writer) void {
    const count = dropped_messages.swap(0, .acq_rel);
    if (count == 0) return;

    var warning: [128]u8 = undefined;
    const line = std.fmt.bufPrint(
        &warning,
        "(logger) [warning]: dropped {d} log messages because the async queue was busy or full\n",
        .{count},
    ) catch return;
    write_raw(file, io, writer, line);
}

fn write_message(file: std.Io.File, io: std.Io, writer: *std.Io.Writer, message: *const LogMessage) void {
    write_raw(file, io, writer, message.slice());
}

fn write_raw(file: std.Io.File, io: std.Io, writer: *std.Io.Writer, bytes: []const u8) void {
    writer.writeAll(bytes) catch {};
    std.debug.print("{s}", .{bytes});
    if (options.config.flush_logs) flush_file(file, io, writer, true);
}

fn flush_file(file: std.Io.File, io: std.Io, writer: *std.Io.Writer, sync_to_storage: bool) void {
    writer.flush() catch {};
    if (sync_to_storage) file.sync(io) catch {};
}

test "message queue is bounded and FIFO" {
    var test_queue: MessageQueue = .{};
    const first = LogMessage{ .len = 1, .bytes = [_]u8{'a'} ** message_capacity };
    const second = LogMessage{ .len = 1, .bytes = [_]u8{'b'} ** message_capacity };

    try std.testing.expect(test_queue.push(first));
    try std.testing.expect(test_queue.push(second));
    try std.testing.expectEqualStrings("a", test_queue.pop().?.slice());
    try std.testing.expectEqualStrings("b", test_queue.pop().?.slice());
    try std.testing.expect(test_queue.pop() == null);

    var index: usize = 0;
    while (index < queue_capacity) : (index += 1) {
        try std.testing.expect(test_queue.push(first));
    }
    try std.testing.expect(!test_queue.push(second));
}
