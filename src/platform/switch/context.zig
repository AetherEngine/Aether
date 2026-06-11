const std = @import("std");
const Util = @import("../../util/util.zig");
const dk = @import("deko.zig");

const Self = @This();
const ENABLE_GPU_ERROR_WATCHER = false;

allocator: std.mem.Allocator,
device: dk.DkDevice = null,
queue: dk.DkQueue = null,
gpu_error_event: dk.Event = undefined,
gpu_error_event_active: bool = false,
gpu_error_thread: ?Util.Thread = null,
gpu_error_thread_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

fn dekoDebugCallback(_: ?*anyopaque, context: [*:0]const u8, result: dk.DkResult, message: [*:0]const u8) callconv(.c) void {
    if (result == dk.ResultSuccess) return;
    std.debug.panic("deko3d {s}: {s} ({d})", .{ std.mem.span(context), std.mem.span(message), result });
}

fn gpuErrorWatcher(self: *Self) void {
    const timeout_ns: u64 = 100 * std.time.ns_per_ms;
    while (!self.gpu_error_thread_stop.load(.acquire)) {
        const rc = dk.eventWait(&self.gpu_error_event, timeout_ns);
        if (rc == 0) {
            std.debug.panic("Switch GPU error detected", .{});
        }
    }
}

fn startGpuErrorWatcher(self: *Self) void {
    self.gpu_error_thread_stop.store(false, .release);
    if (dk.appletGetGpuErrorDetectedSystemEvent(&self.gpu_error_event) != 0) {
        std.log.warn("Switch GPU error event unavailable", .{});
        return;
    }
    self.gpu_error_event_active = true;
    self.gpu_error_thread = Util.Thread.spawn(.{
        .allocator = self.allocator,
        .name = "gpu-error",
        .stack_size = 256 * 1024,
        .priority = .high,
    }, gpuErrorWatcher, .{self}) catch |err| {
        std.log.warn("Switch GPU error watcher unavailable: {s}", .{@errorName(err)});
        dk.eventClose(&self.gpu_error_event);
        self.gpu_error_event_active = false;
        return;
    };
}

fn stopGpuErrorWatcher(self: *Self) void {
    self.gpu_error_thread_stop.store(true, .release);
    if (self.gpu_error_thread) |thread| {
        thread.join();
        self.gpu_error_thread = null;
    }
    if (self.gpu_error_event_active) {
        dk.eventClose(&self.gpu_error_event);
        self.gpu_error_event_active = false;
    }
}

pub fn init(allocator: std.mem.Allocator) !Self {
    var self = Self{ .allocator = allocator };

    var device_maker = dk.DkDeviceMaker{
        .userData = null,
        .cbDebug = dekoDebugCallback,
        .cbAlloc = null,
        .cbFree = null,
        .flags = 0,
    };
    self.device = dk.dkDeviceCreate(&device_maker);
    if (self.device == null) return error.GfxInitFailed;
    errdefer {
        dk.dkDeviceDestroy(self.device);
        self.device = null;
    }

    var queue_maker = dk.DkQueueMaker{
        .device = self.device,
        .flags = dk.QueueGraphics | dk.QueueMediumPrio | dk.QueueEnableZcull,
        .commandMemorySize = dk.QueueMinCmdMemSize,
        .flushThreshold = dk.QueueMinCmdMemSize / 8,
        .perWarpScratchMemorySize = 4 * dk.PerWarpScratchMemAlignment,
        .maxConcurrentComputeJobs = dk.DefaultMaxComputeConcurrentJobs,
    };
    self.queue = dk.dkQueueCreate(&queue_maker);
    if (self.queue == null) return error.GfxInitFailed;
    errdefer {
        dk.dkQueueDestroy(self.queue);
        self.queue = null;
    }
    self.assertQueueOk("queue create");
    if (ENABLE_GPU_ERROR_WATCHER) self.startGpuErrorWatcher();

    return self;
}

pub fn deinit(self: *Self) void {
    self.stopGpuErrorWatcher();
    self.waitIdle("context deinit");
    if (self.queue) |_| {
        dk.dkQueueDestroy(self.queue);
        self.queue = null;
    }
    if (self.device) |_| {
        dk.dkDeviceDestroy(self.device);
        self.device = null;
    }
}

pub fn assertQueueOk(self: *Self, comptime where: []const u8) void {
    if (self.queue) |queue| {
        if (dk.dkQueueIsInErrorState(queue)) {
            std.debug.panic("deko3d queue entered error state after {s}", .{where});
        }
    }
}

pub fn waitIdle(self: *Self, comptime where: []const u8) void {
    if (self.queue) |queue| {
        dk.dkQueueWaitIdle(queue);
        self.assertQueueOk(where);
    }
}

pub fn waitFence(self: *Self, fence: *dk.DkFence, comptime where: []const u8) void {
    const result = dk.dkFenceWait(fence, dk.FenceWaitForever);
    if (result != dk.ResultSuccess) {
        std.debug.panic("deko3d fence wait failed at {s}: {d}", .{ where, result });
    }
    self.assertQueueOk(where);
}

pub fn memBlockMaker(self: *Self, size: u32, flags: u32) dk.DkMemBlockMaker {
    return .{
        .device = self.device,
        .size = dk.alignForward(size, dk.MemBlockAlignment),
        .flags = flags,
        .storage = null,
    };
}

pub fn createMemBlock(self: *Self, size: u32, flags: u32) !dk.DkMemBlock {
    var maker = self.memBlockMaker(size, flags);
    const mem = dk.dkMemBlockCreate(&maker);
    if (mem == null) return error.GfxInitFailed;
    return mem;
}
