const std = @import("std");
const Util = @import("../../util/util.zig");
const logger = @import("../../util/logger.zig");
const dk = @import("deko.zig");

const Self = @This();
const ENABLE_GPU_ERROR_WATCHER = false;
const ENABLE_DEBUG_MARKERS = false;
const ENABLE_GPU_MARKERS = false;
const USE_TIMED_FENCE_WAITS = true;
const DEBUG_GPU_MARKER_SLOT_STRIDE = 64;
const DEBUG_GPU_MARKER_SLOTS = 10;
const DEBUG_GPU_MARKER_BYTES = DEBUG_GPU_MARKER_SLOT_STRIDE * DEBUG_GPU_MARKER_SLOTS;
const FENCE_POLL_NS: i64 = 250 * std.time.ns_per_ms;
const FENCE_LOG_NS: i64 = std.time.ns_per_s;
const FENCE_HANG_NS: i64 = 5 * std.time.ns_per_s;

pub const Marker = enum(u32) {
    none = 0,
    init = 0x0001,
    frame_begin = 0x1000,
    frame_targets = 0x1010,
    frame_clear = 0x1020,
    descriptors = 0x1030,
    draw_begin = 0x2000,
    draw_bound = 0x2010,
    draw_done = 0x2020,
    upload_begin = 0x3000,
    upload_copy = 0x3010,
    upload_submitted = 0x3020,
    wait_idle = 0x3030,
    frame_before_submit = 0x4000,
    frame_submitted = 0x4010,
    frame_presented = 0x4020,
};

const CpuMarkers = struct {
    magic: u32 = 0xA37E_DEB6,
    cpu_phase: u32 = @intFromEnum(Marker.init),
    frame_index: u32 = 0,
    image_index: u32 = 0,
    detail0: u32 = 0,
    detail1: u32 = 0,
    draw_calls: u32 = 0,
    vertex_count: u32 = 0,
};

const GpuMarkerSlot = enum(usize) {
    phase = 0,
    sequence = 1,
    frame_index = 2,
    image_index = 3,
    draw_index = 4,
    mesh_handle = 5,
    vertex_count = 6,
    texture_id = 7,
    buffer_size = 8,
    uniform_slot = 9,
};

var active_context: ?*Self = null;

allocator: std.mem.Allocator,
device: dk.DkDevice = null,
queue: dk.DkQueue = null,
cpu_markers: CpuMarkers = .{},
gpu_marker_mem: dk.DkMemBlock = null,
gpu_marker_gpu_addr: dk.DkGpuAddr = 0,
gpu_marker_cpu: ?[*]volatile u32 = null,
gpu_marker_sequence: u32 = 0,
gpu_error_event: dk.Event = undefined,
gpu_error_event_active: bool = false,
gpu_error_thread: ?Util.Thread = null,
gpu_error_thread_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

fn dumpMarkers(self: *Self) void {
    if (!ENABLE_DEBUG_MARKERS) return;
    const cpu = self.cpu_markers;
    const gpu_phase = self.readGpuMarker(.phase);
    const gpu_sequence = self.readGpuMarker(.sequence);
    const gpu_frame = self.readGpuMarker(.frame_index);
    const gpu_image = self.readGpuMarker(.image_index);
    const gpu_draw = self.readGpuMarker(.draw_index);
    const gpu_mesh = self.readGpuMarker(.mesh_handle);
    const gpu_vertices = self.readGpuMarker(.vertex_count);
    const gpu_texture = self.readGpuMarker(.texture_id);
    const gpu_buffer_size = self.readGpuMarker(.buffer_size);
    const gpu_uniform_slot = self.readGpuMarker(.uniform_slot);
    Util.engine_logger.err(
        "Switch GPU markers: magic=0x{x} cpu=0x{x} gpu=0x{x} frame={d} image={d} detail0=0x{x} detail1=0x{x} draws={d} verts={d} gpu_seq={d} gpu_frame={d} gpu_image={d} gpu_draw={d} gpu_mesh={d} gpu_verts={d} gpu_tex={d} gpu_buf={d} gpu_uniform={d}",
        .{
            cpu.magic,
            cpu.cpu_phase,
            gpu_phase,
            cpu.frame_index,
            cpu.image_index,
            cpu.detail0,
            cpu.detail1,
            cpu.draw_calls,
            cpu.vertex_count,
            gpu_sequence,
            gpu_frame,
            gpu_image,
            gpu_draw,
            gpu_mesh,
            gpu_vertices,
            gpu_texture,
            gpu_buffer_size,
            gpu_uniform_slot,
        },
    );
}

fn gpuMarkerOffset(slot: GpuMarkerSlot) u32 {
    return @intCast(@intFromEnum(slot) * DEBUG_GPU_MARKER_SLOT_STRIDE);
}

fn gpuMarkerCpuIndex(slot: GpuMarkerSlot) usize {
    return gpuMarkerOffset(slot) / @sizeOf(u32);
}

fn readGpuMarker(self: *Self, slot: GpuMarkerSlot) u32 {
    const cpu = self.gpu_marker_cpu orelse return 0;
    return cpu[gpuMarkerCpuIndex(slot)];
}

fn reportGpuMarkerValue(self: *Self, command_buffer: dk.DkCmdBuf, slot: GpuMarkerSlot, value: u32) void {
    dk.dkCmdBufReportValue(command_buffer, value, self.gpu_marker_gpu_addr + gpuMarkerOffset(slot));
}

fn gpuFatal(self: ?*Self, comptime format: []const u8, args: anytype) noreturn {
    Util.engine_logger.err(format, args);
    if (self) |ctx| ctx.dumpMarkers() else if (active_context) |ctx| ctx.dumpMarkers();
    logger.flush();
    std.debug.panic(format, args);
}

fn dekoDebugCallback(_: ?*anyopaque, context: [*:0]const u8, result: dk.DkResult, message: [*:0]const u8) callconv(.c) void {
    if (result == dk.ResultSuccess) return;
    gpuFatal(null, "deko3d {s}: {s} ({d})", .{ std.mem.span(context), std.mem.span(message), result });
}

fn gpuErrorWatcher(self: *Self) void {
    const timeout_ns: u64 = 100 * std.time.ns_per_ms;
    while (!self.gpu_error_thread_stop.load(.acquire)) {
        const rc = dk.eventWait(&self.gpu_error_event, timeout_ns);
        if (rc == 0) {
            gpuFatal(self, "Switch GPU error event signaled", .{});
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
    if (ENABLE_DEBUG_MARKERS) {
        try self.createDebugMarkers();
        errdefer self.destroyDebugMarkers();
    }
    self.assertQueueOk("queue create");
    if (ENABLE_GPU_ERROR_WATCHER) self.startGpuErrorWatcher();

    return self;
}

pub fn deinit(self: *Self) void {
    if (active_context == self) active_context = null;
    self.stopGpuErrorWatcher();
    self.waitIdle("context deinit");
    if (ENABLE_DEBUG_MARKERS) self.destroyDebugMarkers();
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
            gpuFatal(self, "deko3d queue entered error state after {s}", .{where});
        }
    }
}

pub fn waitIdle(self: *Self, comptime where: []const u8) void {
    if (self.queue) |queue| {
        if (!USE_TIMED_FENCE_WAITS) {
            dk.dkQueueWaitIdle(queue);
            self.assertQueueOk(where ++ " idle");
            return;
        }
        var fence = dk.emptyFence();
        dk.dkQueueSignalFence(queue, &fence, true);
        dk.dkQueueFlush(queue);
        self.assertQueueOk(where ++ " idle signal");
        self.waitFence(&fence, where ++ " idle");
    }
}

pub fn flushQueue(self: *Self, comptime where: []const u8) void {
    if (self.queue) |queue| {
        dk.dkQueueFlush(queue);
        self.assertQueueOk(where);
    }
}

pub fn waitFence(self: *Self, fence: *dk.DkFence, comptime where: []const u8) void {
    if (!USE_TIMED_FENCE_WAITS) {
        const result = dk.dkFenceWait(fence, dk.FenceWaitForever);
        if (result != dk.ResultSuccess) {
            gpuFatal(self, "deko3d fence wait failed at {s}: {d}", .{ where, result });
        }
        self.assertQueueOk(where);
        return;
    }

    var waited_ns: i64 = 0;
    var next_log_ns: i64 = FENCE_LOG_NS;
    while (true) {
        const result = dk.dkFenceWait(fence, FENCE_POLL_NS);
        if (result == dk.ResultSuccess) break;
        if (result != dk.ResultTimeout) {
            gpuFatal(self, "deko3d fence wait failed at {s}: {d}", .{ where, result });
        }

        waited_ns += FENCE_POLL_NS;
        if (waited_ns >= next_log_ns) {
            Util.engine_logger.err("deko3d fence wait still pending at {s}: {d} ms", .{ where, @divTrunc(waited_ns, std.time.ns_per_ms) });
            self.dumpMarkers();
            logger.flush();
            next_log_ns += FENCE_LOG_NS;
        }
        if (waited_ns >= FENCE_HANG_NS) {
            gpuFatal(self, "deko3d fence wait timed out at {s}: {d} ms", .{ where, @divTrunc(waited_ns, std.time.ns_per_ms) });
        }
    }
    self.assertQueueOk(where);
}

pub fn panicGpu(comptime format: []const u8, args: anytype) noreturn {
    gpuFatal(active_context, format, args);
}

pub fn activateDiagnostics(self: *Self) void {
    active_context = self;
}

pub fn markCpu(self: *Self, marker: Marker, frame_index: u32, image_index: u32, detail0: u32, detail1: u32) void {
    if (!ENABLE_DEBUG_MARKERS) return;
    self.cpu_markers.cpu_phase = @intFromEnum(marker);
    self.cpu_markers.frame_index = frame_index;
    self.cpu_markers.image_index = image_index;
    self.cpu_markers.detail0 = detail0;
    self.cpu_markers.detail1 = detail1;
}

pub fn markFrameStats(self: *Self, draw_calls: u32, vertex_count: u32) void {
    if (!ENABLE_DEBUG_MARKERS) return;
    self.cpu_markers.draw_calls = draw_calls;
    self.cpu_markers.vertex_count = vertex_count;
}

pub fn markGpu(self: *Self, command_buffer: dk.DkCmdBuf, marker: Marker) void {
    if (!ENABLE_DEBUG_MARKERS) return;
    if (!ENABLE_GPU_MARKERS) return;
    if (self.gpu_marker_gpu_addr == 0) return;
    self.gpu_marker_sequence +%= 1;
    self.reportGpuMarkerValue(command_buffer, .sequence, self.gpu_marker_sequence);
    self.reportGpuMarkerValue(command_buffer, .phase, @intFromEnum(marker));
}

pub fn markGpuDraw(
    self: *Self,
    command_buffer: dk.DkCmdBuf,
    marker: Marker,
    frame_index: u32,
    image_index: u32,
    draw_index: u32,
    mesh_handle: u32,
    vertex_count: u32,
    texture_id: u32,
    buffer_size: u32,
    uniform_slot: u32,
) void {
    if (!ENABLE_DEBUG_MARKERS) return;
    if (!ENABLE_GPU_MARKERS) return;
    if (self.gpu_marker_gpu_addr == 0) return;
    self.gpu_marker_sequence +%= 1;
    self.reportGpuMarkerValue(command_buffer, .sequence, self.gpu_marker_sequence);
    self.reportGpuMarkerValue(command_buffer, .frame_index, frame_index);
    self.reportGpuMarkerValue(command_buffer, .image_index, image_index);
    self.reportGpuMarkerValue(command_buffer, .draw_index, draw_index);
    self.reportGpuMarkerValue(command_buffer, .mesh_handle, mesh_handle);
    self.reportGpuMarkerValue(command_buffer, .vertex_count, vertex_count);
    self.reportGpuMarkerValue(command_buffer, .texture_id, texture_id);
    self.reportGpuMarkerValue(command_buffer, .buffer_size, buffer_size);
    self.reportGpuMarkerValue(command_buffer, .uniform_slot, uniform_slot);
    self.reportGpuMarkerValue(command_buffer, .phase, @intFromEnum(marker));
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

fn createDebugMarkers(self: *Self) !void {
    self.cpu_markers = .{};
    self.gpu_marker_mem = try self.createMemBlock(DEBUG_GPU_MARKER_BYTES, dk.MemCpuUncached | dk.MemGpuUncached | dk.MemZeroFillInit);
    errdefer {
        dk.dkMemBlockDestroy(self.gpu_marker_mem);
        self.gpu_marker_mem = null;
    }
    self.gpu_marker_gpu_addr = dk.dkMemBlockGetGpuAddr(self.gpu_marker_mem);
    self.gpu_marker_cpu = @ptrCast(@alignCast(dk.dkMemBlockGetCpuAddr(self.gpu_marker_mem) orelse return error.GfxInitFailed));
    self.gpu_marker_sequence = 0;
    inline for (std.enums.values(GpuMarkerSlot)) |slot| {
        self.gpu_marker_cpu.?[gpuMarkerCpuIndex(slot)] = 0;
    }
    _ = dk.dkMemBlockFlushCpuCache(self.gpu_marker_mem, 0, DEBUG_GPU_MARKER_BYTES);
    Util.engine_logger.info("Switch GPU diagnostics: report gpu=0x{x} bytes={d}", .{ self.gpu_marker_gpu_addr, DEBUG_GPU_MARKER_BYTES });
}

fn destroyDebugMarkers(self: *Self) void {
    self.gpu_marker_cpu = null;
    self.gpu_marker_gpu_addr = 0;
    self.gpu_marker_sequence = 0;
    if (self.gpu_marker_mem) |mem| {
        dk.dkMemBlockDestroy(mem);
        self.gpu_marker_mem = null;
    }
}
