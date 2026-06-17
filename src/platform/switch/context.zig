const std = @import("std");
const Util = @import("../../util/util.zig");
const logger = @import("../../util/logger.zig");
const dk = @import("deko.zig");

const Self = @This();
const ENABLE_GPU_MARKERS = false;
const DEBUG_GPU_MARKER_SLOT_STRIDE = 64;
const DEBUG_GPU_MARKER_SLOTS = 10;
const DEBUG_GPU_MARKER_BYTES = DEBUG_GPU_MARKER_SLOT_STRIDE * DEBUG_GPU_MARKER_SLOTS;
const FENCE_POLL_NS: i64 = 250 * std.time.ns_per_ms;
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
gpu_marker_mem: dk.DkMemBlock = null,
gpu_marker_gpu_addr: dk.DkGpuAddr = 0,
gpu_marker_cpu: ?[*]volatile u32 = null,
gpu_marker_sequence: u32 = 0,

fn dump_gpu_markers(self: *Self) void {
    if (!ENABLE_GPU_MARKERS) return;
    Util.engine_logger.err(
        "Switch GPU markers: phase=0x{x} sequence={d} frame={d} image={d} draw={d} mesh={d} vertices={d} texture={d} buffer={d} uniform={d}",
        .{
            self.read_gpu_marker(.phase),
            self.read_gpu_marker(.sequence),
            self.read_gpu_marker(.frame_index),
            self.read_gpu_marker(.image_index),
            self.read_gpu_marker(.draw_index),
            self.read_gpu_marker(.mesh_handle),
            self.read_gpu_marker(.vertex_count),
            self.read_gpu_marker(.texture_id),
            self.read_gpu_marker(.buffer_size),
            self.read_gpu_marker(.uniform_slot),
        },
    );
}

fn gpu_marker_offset(slot: GpuMarkerSlot) u32 {
    return @intCast(@intFromEnum(slot) * DEBUG_GPU_MARKER_SLOT_STRIDE);
}

fn gpu_marker_cpu_index(slot: GpuMarkerSlot) usize {
    return gpu_marker_offset(slot) / @sizeOf(u32);
}

fn read_gpu_marker(self: *Self, slot: GpuMarkerSlot) u32 {
    const cpu = self.gpu_marker_cpu orelse return 0;
    return cpu[gpu_marker_cpu_index(slot)];
}

fn report_gpu_marker_value(self: *Self, command_buffer: dk.DkCmdBuf, slot: GpuMarkerSlot, value: u32) void {
    dk.dkCmdBufReportValue(command_buffer, value, self.gpu_marker_gpu_addr + gpu_marker_offset(slot));
}

fn gpu_fatal(self: ?*Self, comptime format: []const u8, args: anytype) noreturn {
    Util.engine_logger.err(format, args);
    if (self) |ctx| ctx.dump_gpu_markers() else if (active_context) |ctx| ctx.dump_gpu_markers();
    logger.flush();
    std.debug.panic(format, args);
}

fn c_string(ptr: [*c]const u8) []const u8 {
    return std.mem.span(@as([*:0]const u8, @ptrCast(ptr)));
}

fn deko_debug_callback(_: ?*anyopaque, context: [*c]const u8, result: dk.DkResult, message: [*c]const u8) callconv(.c) void {
    if (result == dk.ResultSuccess) return;
    gpu_fatal(null, "deko3d {s}: {s} ({d})", .{ c_string(context), c_string(message), result });
}

pub fn init(allocator: std.mem.Allocator) !Self {
    var self = Self{ .allocator = allocator };

    var device_maker = dk.DkDeviceMaker{
        .userData = null,
        .cbDebug = deko_debug_callback,
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
    if (ENABLE_GPU_MARKERS) {
        try self.create_gpu_markers();
        errdefer self.destroy_gpu_markers();
    }
    self.assert_queue_ok("queue create");

    return self;
}

pub fn deinit(self: *Self) void {
    if (active_context == self) active_context = null;
    self.wait_idle("context deinit");
    if (ENABLE_GPU_MARKERS) self.destroy_gpu_markers();
    if (self.queue) |_| {
        dk.dkQueueDestroy(self.queue);
        self.queue = null;
    }
    if (self.device) |_| {
        dk.dkDeviceDestroy(self.device);
        self.device = null;
    }
}

pub fn assert_queue_ok(self: *Self, comptime where: []const u8) void {
    if (self.queue) |queue| {
        if (dk.dkQueueIsInErrorState(queue)) {
            gpu_fatal(self, "deko3d queue entered error state after {s}", .{where});
        }
    }
}

pub fn wait_idle(self: *Self, comptime where: []const u8) void {
    if (self.queue) |queue| {
        var fence = dk.emptyFence();
        dk.dkQueueSignalFence(queue, &fence, true);
        dk.dkQueueFlush(queue);
        self.assert_queue_ok(where ++ " idle signal");
        self.wait_fence(&fence, where ++ " idle");
    }
}

pub fn flush_queue(self: *Self, comptime where: []const u8) void {
    if (self.queue) |queue| {
        dk.dkQueueFlush(queue);
        self.assert_queue_ok(where);
    }
}

pub fn wait_fence(self: *Self, fence: *dk.DkFence, comptime where: []const u8) void {
    var waited_ns: i64 = 0;
    while (true) {
        const result = dk.dkFenceWait(fence, FENCE_POLL_NS);
        if (result == dk.ResultSuccess) break;
        if (result != dk.ResultTimeout) {
            gpu_fatal(self, "deko3d fence wait failed at {s}: {d}", .{ where, result });
        }

        waited_ns += FENCE_POLL_NS;
        if (waited_ns >= FENCE_HANG_NS) {
            gpu_fatal(self, "deko3d fence wait timed out at {s}: {d} ms", .{ where, @divTrunc(waited_ns, std.time.ns_per_ms) });
        }
    }
    self.assert_queue_ok(where);
}

pub fn panic_gpu(comptime format: []const u8, args: anytype) noreturn {
    gpu_fatal(active_context, format, args);
}

pub fn activate(self: *Self) void {
    active_context = self;
}

pub fn mark_gpu(self: *Self, command_buffer: dk.DkCmdBuf, marker: Marker) void {
    if (!ENABLE_GPU_MARKERS) return;
    if (self.gpu_marker_gpu_addr == 0) return;
    self.gpu_marker_sequence +%= 1;
    self.report_gpu_marker_value(command_buffer, .sequence, self.gpu_marker_sequence);
    self.report_gpu_marker_value(command_buffer, .phase, @intFromEnum(marker));
}

pub fn mark_gpu_draw(
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
    if (!ENABLE_GPU_MARKERS) return;
    if (self.gpu_marker_gpu_addr == 0) return;
    self.gpu_marker_sequence +%= 1;
    self.report_gpu_marker_value(command_buffer, .sequence, self.gpu_marker_sequence);
    self.report_gpu_marker_value(command_buffer, .frame_index, frame_index);
    self.report_gpu_marker_value(command_buffer, .image_index, image_index);
    self.report_gpu_marker_value(command_buffer, .draw_index, draw_index);
    self.report_gpu_marker_value(command_buffer, .mesh_handle, mesh_handle);
    self.report_gpu_marker_value(command_buffer, .vertex_count, vertex_count);
    self.report_gpu_marker_value(command_buffer, .texture_id, texture_id);
    self.report_gpu_marker_value(command_buffer, .buffer_size, buffer_size);
    self.report_gpu_marker_value(command_buffer, .uniform_slot, uniform_slot);
    self.report_gpu_marker_value(command_buffer, .phase, @intFromEnum(marker));
}

pub fn create_mem_block(self: *Self, size: u32, flags: u32) !dk.DkMemBlock {
    var maker = dk.DkMemBlockMaker{
        .device = self.device,
        .size = dk.alignForward(size, dk.MemBlockAlignment),
        .flags = flags,
        .storage = null,
    };
    const mem = dk.dkMemBlockCreate(&maker);
    if (mem == null) return error.GfxInitFailed;
    return mem;
}

fn create_gpu_markers(self: *Self) !void {
    self.gpu_marker_mem = try self.create_mem_block(DEBUG_GPU_MARKER_BYTES, dk.MemCpuUncached | dk.MemGpuUncached | dk.MemZeroFillInit);
    errdefer {
        dk.dkMemBlockDestroy(self.gpu_marker_mem);
        self.gpu_marker_mem = null;
    }
    self.gpu_marker_gpu_addr = dk.dkMemBlockGetGpuAddr(self.gpu_marker_mem);
    self.gpu_marker_cpu = @ptrCast(@alignCast(dk.dkMemBlockGetCpuAddr(self.gpu_marker_mem) orelse return error.GfxInitFailed));
    self.gpu_marker_sequence = 0;
    inline for (std.enums.values(GpuMarkerSlot)) |slot| {
        self.gpu_marker_cpu.?[gpu_marker_cpu_index(slot)] = 0;
    }
    _ = dk.dkMemBlockFlushCpuCache(self.gpu_marker_mem, 0, DEBUG_GPU_MARKER_BYTES);
}

fn destroy_gpu_markers(self: *Self) void {
    self.gpu_marker_cpu = null;
    self.gpu_marker_gpu_addr = 0;
    self.gpu_marker_sequence = 0;
    if (self.gpu_marker_mem) |mem| {
        dk.dkMemBlockDestroy(mem);
        self.gpu_marker_mem = null;
    }
}
