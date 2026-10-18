//! Bounded FIFO jobs. Threaded mode has one worker; manual/inline modes must be
//! driven on one app thread. Inline submission also belongs to that thread.
//! Jobs and their context remain borrowed until done. Shutdown/deinit are
//! single-owner operations and must not race a driver or another shutdown.
const std = @import("std");
const assert = std.debug.assert;
const platform = @import("platform");

pub const Job = struct {
    pub const State = enum(u32) { idle, queued, running, done, cancelled };
    context: *anyopaque,
    run: *const fn (*anyopaque) anyerror!void,
    state: std.atomic.Value(State) = .init(.idle),
    err: ?anyerror = null,

    pub fn is_done(self: *const Job) bool {
        return switch (self.state.load(.acquire)) {
            .done, .cancelled => true,
            else => false,
        };
    }

    /// Read only after completion; resubmission requires all readers to finish.
    pub fn result(self: *const Job) !void {
        if (!self.is_done()) return error.Incomplete;
        if (self.err) |err| return err;
    }

    /// Requires another thread to execute the job. Cancellation of this wait
    /// does not cancel the callback or release its borrowed storage. For manual/inline execution,
    /// drive run_pending then inspect result instead of blocking the app thread.
    pub fn wait(self: *Job, io: std.Io) !void {
        while (true) {
            const state = self.state.load(.acquire);
            switch (state) {
                .idle => return error.NotSubmitted,
                .done, .cancelled => return self.result(),
                .queued, .running => try std.Io.sleep(io, .fromMilliseconds(1), .real),
            }
        }
    }

    fn finish(self: *Job, err: ?anyerror, state: State) void {
        self.err = err;
        // This final store is the last access to borrowed job storage. A
        // polling consumer may immediately release it after observing done.
        self.state.store(state, .release);
    }
};

pub const Mode = enum { auto, threaded, manual, inline_execution };
pub const Options = struct {
    capacity: usize = 32,
    mode: Mode = .auto,
    thread: platform.thread.Config = .{ .name = "aether_jobs", .priority = .low },
};

pub const Executor = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    mode: Mode,
    queue: []*Job,
    count: usize = 0,
    mutex: std.Io.Mutex = .init,
    ready: std.Io.Condition = .init,
    closing: bool = false,
    driving: bool = false,
    worker: ?platform.thread.Thread = null,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, opts: Options) !*Executor {
        if (opts.capacity == 0) return error.InvalidCapacity;
        const threaded = platform.system.info().background_workers;
        const mode = if (opts.mode == .auto) (if (threaded) Mode.threaded else Mode.inline_execution) else opts.mode;
        if (mode == .threaded and !threaded) return error.UnsupportedPlatform;
        const self = try allocator.create(Executor);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .io = io, .mode = mode, .queue = try allocator.alloc(*Job, opts.capacity) };
        errdefer allocator.free(self.queue);
        if (mode == .threaded) {
            var cfg = opts.thread;
            cfg.allocator = allocator;
            cfg.io = io;
            self.worker = try platform.thread.Thread.spawn(cfg, worker_main, .{self});
        }
        return self;
    }

    /// Starts the worker after an application finishes initialization. Queued
    /// manual jobs retain their FIFO order. Stop producers/manual drivers while
    /// changing modes; a failed spawn leaves the manual executor usable.
    pub fn start_thread(self: *Executor, config: platform.thread.Config) !void {
        if (!platform.system.info().background_workers) return error.UnsupportedPlatform;
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        if (self.closing) return error.ShuttingDown;
        if (self.mode != .manual or self.driving) return error.InvalidMode;
        var cfg = config;
        cfg.allocator = self.allocator;
        cfg.io = self.io;
        self.mode = .threaded;
        self.worker = platform.thread.Thread.spawn(cfg, worker_main, .{self}) catch |err| {
            self.mode = .manual;
            return err;
        };
    }

    /// Nonblocking queue admission. A running/queued job cannot be resubmitted.
    /// Inline mode drains before the outermost submit returns. A submission
    /// inside a callback runs after that callback returns; never wait for a
    /// nested job from its parent callback.
    pub fn submit(self: *Executor, job: *Job) !void {
        self.mutex.lockUncancelable(self.io);
        if (self.closing) {
            self.mutex.unlock(self.io);
            return error.ShuttingDown;
        }
        if (self.count == self.queue.len) {
            self.mutex.unlock(self.io);
            return error.QueueFull;
        }
        const state = job.state.load(.acquire);
        if (state == .queued or state == .running or job.state.cmpxchgStrong(state, .queued, .acq_rel, .acquire) != null) {
            self.mutex.unlock(self.io);
            return error.AlreadySubmitted;
        }
        self.queue[self.count] = job;
        self.count += 1;
        self.ready.signal(self.io);
        self.mutex.unlock(self.io);
        if (self.mode == .inline_execution) _ = try self.run_pending(std.math.maxInt(usize));
    }

    /// Cancels only work still queued in this executor. Running callbacks are
    /// never interrupted; they retain their input until returning.
    pub fn cancel(self: *Executor, job: *Job) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        for (self.queue[0..self.count], 0..) |queued, i| {
            if (queued != job) continue;
            self.remove(i);
            job.finish(error.Canceled, .cancelled);
            return true;
        }
        return false;
    }

    fn remove(self: *Executor, i: usize) void {
        std.mem.copyForwards(*Job, self.queue[i .. self.count - 1], self.queue[i + 1 .. self.count]);
        self.count -= 1;
    }

    fn take(self: *Executor) ?*Job {
        if (self.count == 0) return null;
        const job = self.queue[0];
        self.remove(0);
        job.state.store(.running, .release);
        return job;
    }

    fn execute(_: *Executor, job: *Job) void {
        job.run(job.context) catch |err| {
            job.finish(err, .done);
            return;
        };
        job.finish(null, .done);
    }

    /// Runs whole callbacks, not time slices. max_jobs bounds count, not elapsed
    /// time. Long cooperative tasks must expose resumable steps themselves.
    pub fn run_pending(self: *Executor, max_jobs: usize) !usize {
        if (self.mode == .threaded) return error.ThreadedExecutor;
        if (self.driving) return 0;
        self.driving = true;
        defer self.driving = false;

        var ran: usize = 0;
        while (ran < max_jobs) : (ran += 1) {
            self.mutex.lockUncancelable(self.io);
            const job = self.take();
            self.mutex.unlock(self.io);
            self.execute(job orelse break);
        }
        return ran;
    }

    fn worker_main(self: *Executor) void {
        while (true) {
            self.mutex.lockUncancelable(self.io);
            while (self.count == 0 and !self.closing) self.ready.waitUncancelable(self.io, &self.mutex);
            const job = self.take();
            self.mutex.unlock(self.io);
            self.execute(job orelse return);
        }
    }

    /// Rejects submissions, drains or cancels queued jobs, and joins the running
    /// callback. Call outside callbacks, after producers have stopped. Idempotent.
    pub fn shutdown(self: *Executor, cancel_queued: bool) void {
        assert(!self.driving);
        self.mutex.lockUncancelable(self.io);
        self.closing = true;
        if (cancel_queued) {
            for (self.queue[0..self.count]) |job| job.finish(error.Canceled, .cancelled);
            self.count = 0;
        }
        self.ready.broadcast(self.io);
        self.mutex.unlock(self.io);
        if (self.worker) |worker| {
            worker.join();
            self.worker = null;
        } else if (self.mode != .threaded) {
            _ = self.run_pending(std.math.maxInt(usize)) catch unreachable;
        }
    }

    pub fn deinit(self: *Executor) void {
        self.shutdown(false);
        const allocator = self.allocator;
        allocator.free(self.queue);
        self.* = undefined;
        allocator.destroy(self);
    }
};
