pub const CreateInfo = struct {
    linear_gpa: std.mem.Allocator,
};

const vtable: Device.VTable = .{
    .destroy = destroy,

    .reacquire = reacquire,
    .release = release,

    .waitIdleQueue = waitIdleQueue,
    .wakeIdleQueue = wakeIdleQueue,

    .getShaderCode = getShaderCode,
    .destroyShaderCode = destroyShaderCode,

    .allocateMemory = allocateMemory,
    .freeMemory = freeMemory,
    .mapMemory = mapMemory,
    .unmapMemory = unmapMemory,
    .flushMappedMemoryRanges = flushMappedMemoryRanges,
    .invalidateMappedMemoryRanges = invalidateMappedMemoryRanges,

    .createSwapchain = createSwapchain,
    .destroySwapchain = destroySwapchain,
    .getSwapchainImages = getSwapchainImages,
    .acquireNextImage = acquireNextImage,

    .waitSemaphores = waitSemaphores,
    .signalSemaphore = signalSemaphore,

    .virtualToPhysical = virtualToPhysical,
};

const CodeCache = struct {
    const Key = backend.Shader.Code.Key;
    const Context = struct {
        pub fn eql(_: Context, a: Key, b: Key, _: usize) bool {
            return a.hash == b.hash and
                std.mem.eql(pica.shader.encoding.Instruction, a.instructions, b.instructions) and
                std.mem.eql(pica.shader.encoding.OperandDescriptor, a.descriptors, b.descriptors);
        }

        pub fn hash(_: Context, key: Key) u32 {
            return key.hash;
        }
    };

    uid: u32 = 0,
    entries: std.ArrayHashMapUnmanaged(Key, *backend.Shader.Code, Context, false) = .empty,

    fn deinit(cache: *CodeCache, gpa: std.mem.Allocator) void {
        var it = cache.entries.iterator();
        while (it.next()) |entry| {
            const code = entry.value_ptr.*;
            gpa.free(code.instructions);
            gpa.free(code.descriptors);
            gpa.destroy(code);
        }
        cache.entries.deinit(gpa);
        cache.* = .{};
    }

    fn getOrAdd(cache: *CodeCache, gpa: std.mem.Allocator, key: Key) !*backend.Shader.Code {
        const entry = try cache.entries.getOrPut(gpa, key);
        errdefer cache.entries.swapRemoveAt(entry.index);

        if (entry.found_existing) {
            const code = entry.value_ptr.*;
            std.debug.assert(code.ref.fetchAdd(1, .monotonic) > 0);
            return code;
        }

        const new_code = try gpa.create(backend.Shader.Code);
        errdefer gpa.destroy(new_code);

        const instructions = try gpa.dupe(pica.shader.encoding.Instruction, key.instructions);
        errdefer gpa.free(instructions);

        const descriptors = try gpa.dupe(pica.shader.encoding.OperandDescriptor, key.descriptors);
        errdefer gpa.free(descriptors);

        new_code.* = .init(cache.uid, key.hash, instructions, descriptors);
        cache.uid +%= 1;
        entry.value_ptr.* = new_code;
        return new_code;
    }

    fn destroy(cache: *CodeCache, gpa: std.mem.Allocator, code: *backend.Shader.Code) void {
        std.debug.assert(code.ref.load(.monotonic) == 0);
        const key: Key = .initCode(code);
        std.debug.assert(cache.entries.swapRemove(key));
        gpa.free(code.instructions);
        gpa.free(code.descriptors);
        gpa.destroy(code);
    }
};

device: Device,
code_cache: CodeCache = .{},

pub fn create(create_info: CreateInfo, gpa: std.mem.Allocator) !*AetherCtru {
    const actru = try gpa.create(AetherCtru);
    errdefer gpa.destroy(actru);

    var fill_queue: Queue = try .init(gpa, .fill, &actru.device, backend.max_buffered_queue_items, @sizeOf(Queue.FillItem), .of(Queue.FillItem));
    errdefer fill_queue.deinit(gpa);

    var transfer_queue: Queue = try .init(gpa, .transfer, &actru.device, backend.max_buffered_queue_items, @sizeOf(Queue.TransferItem), .of(Queue.TransferItem));
    errdefer transfer_queue.deinit(gpa);

    var submit_queue: Queue = try .init(gpa, .submit, &actru.device, backend.max_buffered_queue_items, @sizeOf(Queue.SubmitItem), .of(Queue.SubmitItem));
    errdefer submit_queue.deinit(gpa);

    var present_queue: Queue = try .init(gpa, .present, &actru.device, backend.max_present_queue_items, @sizeOf(Queue.PresentationItem), .of(Queue.PresentationItem));
    errdefer present_queue.deinit(gpa);

    actru.* = .{
        .device = .{
            .gpa = gpa,
            .linear_gpa = create_info.linear_gpa,
            .vtable = vtable,
            .queues = .init(.{
                .fill = fill_queue,
                .transfer = transfer_queue,
                .submit = submit_queue,
                .present = present_queue,
            }),
            .queue_statuses = .initDefault(.init(.idle), .{}),
        },
        .code_cache = .{},
    };

    return actru;
}

fn destroy(dev: *Device) void {
    const gpa = dev.gpa;
    const actru: *AetherCtru = @alignCast(@fieldParentPtr("device", dev));

    _ = drainAll(actru);
    actru.code_cache.deinit(gpa);
    for (std.enums.values(Queue.Type)) |typ| actru.device.queues.getPtr(typ).deinit(gpa);
    gpa.destroy(actru);
}

fn reacquire(_: *Device) mango.ReacquireDeviceError!void {}

fn release(dev: *Device) mango.ReleaseDeviceError!Device.ScreenCapture {
    dev.waitIdle();
    return .{};
}

fn waitIdleQueue(dev: *Device, queue: Queue.Type) void {
    const actru: *AetherCtru = @alignCast(@fieldParentPtr("device", dev));
    _ = drainQueue(actru, queue);
}

fn wakeIdleQueue(dev: *Device, _: Queue.Type) void {
    const actru: *AetherCtru = @alignCast(@fieldParentPtr("device", dev));
    _ = drainAll(actru);
}

fn getShaderCode(dev: *Device, key: backend.Shader.Code.Key) mango.ObjectCreationError!*backend.Shader.Code {
    const actru: *AetherCtru = @alignCast(@fieldParentPtr("device", dev));
    return actru.code_cache.getOrAdd(dev.gpa, key) catch error.OutOfMemory;
}

fn destroyShaderCode(dev: *Device, code: *backend.Shader.Code) void {
    const actru: *AetherCtru = @alignCast(@fieldParentPtr("device", dev));
    actru.code_cache.destroy(dev.gpa, code);
}

fn allocateMemory(dev: *Device, allocate_info: mango.MemoryAllocateInfo, _: std.mem.Allocator) mango.ObjectCreationError!mango.DeviceMemory {
    const size = std.mem.alignForward(usize, @intFromEnum(allocate_info.allocation_size), page_size);
    const ptr: [*]align(page_size) u8 = switch (allocate_info.memory_type) {
        .fcram_cached => fcram: {
            const mem = dev.linear_gpa.alignedAlloc(u8, .fromByteUnits(page_size), size) catch return error.OutOfMemory;
            break :fcram mem.ptr;
        },
        .vram_a, .vram_b => |bank| vram: {
            const pos: c.vramAllocPos = @intCast(switch (bank) {
                .vram_a => c.VRAM_ALLOC_A,
                .vram_b => c.VRAM_ALLOC_B,
                else => unreachable,
            });
            const mem = c.vramMemAlignAt(size, page_size, pos) orelse return error.OutOfMemory;
            break :vram @ptrCast(@alignCast(mem));
        },
    };

    const phys = virtualToPhysical(dev, ptr);
    const heap: backend.DeviceMemory.MemoryHeap = switch (allocate_info.memory_type) {
        .fcram_cached => .fcram,
        .vram_a => .vram_a,
        .vram_b => .vram_b,
    };

    return (backend.DeviceMemory{
        .data = .init(ptr, phys, size, heap),
    }).toHandle();
}

fn freeMemory(dev: *Device, memory: mango.DeviceMemory, _: std.mem.Allocator) void {
    const b_memory: backend.DeviceMemory = .fromHandle(memory);
    if (!b_memory.data.valid) return;

    switch (b_memory.data.heap) {
        .fcram => {
            const ptr: [*]align(page_size) u8 = @alignCast(b_memory.virtualAddress());
            dev.linear_gpa.free(ptr[0..b_memory.size()]);
        },
        .vram_a, .vram_b => c.vramFree(b_memory.virtualAddress()),
    }
}

fn mapMemory(_: *Device, memory: mango.DeviceMemory, offset: mango.DeviceSize, size: mango.DeviceSize) mango.MapMemoryError![]u8 {
    const b_memory: backend.DeviceMemory = .fromHandle(memory);
    const b_offset = @intFromEnum(offset);
    std.debug.assert(b_offset <= b_memory.size());

    const len = switch (size) {
        .whole => b_memory.size() - b_offset,
        _ => |sz| @intFromEnum(sz),
    };
    std.debug.assert(b_offset + len <= b_memory.size());

    return (b_memory.virtualAddress() + b_offset)[0..len];
}

fn unmapMemory(_: *Device, _: mango.DeviceMemory) void {}

fn flushMappedMemoryRanges(_: *Device, ranges: []const mango.MappedMemoryRange) mango.FlushMemoryError!void {
    for (ranges) |range| {
        const bytes = mappedRange(range);
        if (bytes.len == 0) continue;
        if (c.GSPGPU_FlushDataCache(bytes.ptr, @intCast(bytes.len)) != 0) return error.Unexpected;
    }
}

fn invalidateMappedMemoryRanges(_: *Device, ranges: []const mango.MappedMemoryRange) mango.InvalidateMemoryError!void {
    for (ranges) |range| {
        const bytes = mappedRange(range);
        if (bytes.len == 0) continue;
        if (c.GSPGPU_InvalidateDataCache(bytes.ptr, @intCast(bytes.len)) != 0) return error.Unexpected;
    }
}

fn mappedRange(range: mango.MappedMemoryRange) []u8 {
    const b_memory: backend.DeviceMemory = .fromHandle(range.memory);
    const offset = @intFromEnum(range.offset);
    const len = switch (range.size) {
        .whole => b_memory.size() - offset,
        _ => |sz| @intFromEnum(sz),
    };
    std.debug.assert(offset + len <= b_memory.size());
    return (b_memory.virtualAddress() + offset)[0..len];
}

fn createSwapchain(_: *Device, _: mango.SwapchainCreateInfo, _: std.mem.Allocator) mango.ObjectCreationError!mango.Swapchain {
    return error.Unexpected;
}

fn destroySwapchain(_: *Device, _: mango.Swapchain, _: std.mem.Allocator) void {}

fn getSwapchainImages(_: *Device, _: mango.Swapchain, _: []mango.Image) mango.GetSwapchainImagesError!u8 {
    return error.Unexpected;
}

fn acquireNextImage(_: *Device, _: mango.Swapchain, _: u64) mango.AcquireNextImageError!u8 {
    return error.Unexpected;
}

fn waitSemaphores(dev: *Device, wait_info: mango.SemaphoreWaitInfo, _: u64) mango.WaitSemaphoreError!void {
    const actru: *AetherCtru = @alignCast(@fieldParentPtr("device", dev));
    const semaphores = wait_info.semaphores[0..wait_info.semaphore_count];
    const values = wait_info.values[0..wait_info.semaphore_count];

    while (true) {
        var satisfied = true;
        for (semaphores, values) |semaphore, value| {
            const b_semaphore: *backend.Semaphore = .fromHandleMutable(semaphore);
            if (b_semaphore.counterValue() < value) {
                satisfied = false;
                break;
            }
        }
        if (satisfied) return;

        if (!drainAll(actru)) return error.Timeout;
    }
}

fn signalSemaphore(_: *Device, signal_info: mango.SemaphoreSignalInfo) mango.SignalSemaphoreError!void {
    const b_semaphore: *backend.Semaphore = .fromHandleMutable(signal_info.semaphore);
    _ = b_semaphore.signal(signal_info.value);
}

fn virtualToPhysical(_: *Device, virtual: *const anyopaque) zitrus.hardware.PhysicalAddress {
    return .fromAddress(c.osConvertVirtToPhys(virtual));
}

fn drainAll(actru: *AetherCtru) bool {
    var progressed = false;
    while (true) {
        var pass_progress = false;
        inline for (.{ Queue.Type.submit, .fill, .transfer, .present }) |typ| {
            pass_progress = drainQueue(actru, typ) or pass_progress;
        }
        if (!pass_progress) break;
        progressed = true;
    }
    return progressed;
}

fn drainQueue(actru: *AetherCtru, typ: Queue.Type) bool {
    const dev = &actru.device;
    const queue = dev.queues.getPtr(typ);
    var progressed = false;

    while (true) switch (queue.peekBack()) {
        .empty => {
            dev.queue_statuses.getPtr(typ).store(.idle, .monotonic);
            return progressed;
        },
        .wait => {
            dev.queue_statuses.getPtr(typ).store(.waiting, .monotonic);
            return progressed;
        },
        .ready => {
            dev.queue_statuses.getPtr(typ).store(.working, .monotonic);
            const signal = switch (typ) {
                .fill => fill: {
                    const item, const sig = queue.popBackAssumeReady(Queue.FillItem);
                    processFill(item) catch dev.queue_statuses.getPtr(typ).store(.lost, .monotonic);
                    break :fill sig;
                },
                .transfer => transfer: {
                    const item, const sig = queue.popBackAssumeReady(Queue.TransferItem);
                    processTransfer(item) catch dev.queue_statuses.getPtr(typ).store(.lost, .monotonic);
                    break :transfer sig;
                },
                .submit => submit: {
                    const item, const sig = queue.popBackAssumeReady(Queue.SubmitItem);
                    processSubmit(item) catch dev.queue_statuses.getPtr(typ).store(.lost, .monotonic);
                    item.cmd_buffer.notifyCompleted();
                    break :submit sig;
                },
                .present => present: {
                    const popped = queue.popBackAssumeReady(Queue.PresentationItem);
                    break :present popped[1];
                },
            };

            if (signal.sema) |sema| _ = sema.signal(signal.value);
            dev.queue_statuses.getPtr(typ).store(.work_completed, .monotonic);
            progressed = true;
        },
    };
}

fn processSubmit(item: Queue.SubmitItem) !void {
    var maybe_node = item.cmd_buffer.head;
    while (maybe_node) |node| {
        switch (node.kind) {
            .graphics => {
                const gfx: *CommandBuffer.operation.Graphics = @alignCast(@fieldParentPtr("node", node));
                if (gfx.len > 0) {
                    if (c.GSPGPU_FlushDataCache(gfx.head, gfx.len * @sizeOf(u32)) != 0) return error.Unexpected;
                    if (c.GX_ProcessCommandList(@ptrCast(@constCast(gfx.head)), gfx.len * @sizeOf(u32), c.GX_CMDLIST_FLUSH) != 0) return error.Unexpected;
                }
            },
            .timestamp, .begin_query, .end_query => {},
        }
        maybe_node = node.nextPtr();
    }
}

fn processFill(item: Queue.FillItem) !void {
    if (item.data.len == 0) return;
    const value, const control = fillValueControl(item.value);
    const start: *u32 = @ptrCast(@alignCast(item.data.ptr));
    const end: *u32 = @ptrCast(@alignCast(item.data.ptr + item.data.len));
    if (c.GX_MemoryFill(start, value, end, control, null, 0, null, 0) != 0) return error.Unexpected;
}

fn fillValueControl(value: Queue.FillValue) struct { u32, u16 } {
    return switch (value) {
        .fill16 => |v| .{ v, c.GX_FILL_TRIGGER | c.GX_FILL_16BIT_DEPTH },
        .fill24 => |v| .{ v, c.GX_FILL_TRIGGER | c.GX_FILL_24BIT_DEPTH },
        .fill32 => |v| .{ v, c.GX_FILL_TRIGGER | c.GX_FILL_32BIT_DEPTH },
    };
}

fn processTransfer(item: Queue.TransferItem) !void {
    switch (item.flags.kind) {
        .copy => {
            const size = item.flags.extra.copy;
            if (size == 0) return;
            if (c.GX_TextureCopy(
                @ptrCast(@constCast(item.src)),
                gxBufferDim(item.input_gap_size[0], item.input_gap_size[1]),
                @ptrCast(item.dst),
                gxBufferDim(item.output_gap_size[0], item.output_gap_size[1]),
                size,
                0,
            ) != 0) return error.Unexpected;
        },
        .linear_tiled, .tiled_linear, .tiled_tiled => {
            const flags = transferFlags(item);
            if (c.GX_DisplayTransfer(
                @ptrCast(@constCast(item.src)),
                gxBufferDim(item.input_gap_size[0], item.input_gap_size[1]),
                @ptrCast(item.dst),
                gxBufferDim(item.output_gap_size[0], item.output_gap_size[1]),
                flags,
            ) != 0) return error.Unexpected;
        },
    }
}

fn gxBufferDim(width: u16, height: u16) u32 {
    return (@as(u32, height) << 16) | @as(u32, width);
}

fn transferFlags(item: Queue.TransferItem) u32 {
    const transfer = item.flags.extra.transfer;
    const mode = switch (item.flags.kind) {
        .copy => unreachable,
        .linear_tiled => .{ false, true, false },
        .tiled_linear => .{ false, false, false },
        .tiled_tiled => .{ false, true, true },
    };

    const flip_vert, const out_tiled, const raw_copy = mode;
    return (@as(u32, @intFromBool(flip_vert)) << 0) |
        (@as(u32, @intFromBool(out_tiled)) << 1) |
        (@as(u32, @intFromBool(raw_copy)) << 3) |
        (@as(u32, @intCast(gxFormat(transfer.src_fmt))) << 8) |
        (@as(u32, @intCast(gxFormat(transfer.dst_fmt))) << 12) |
        (@as(u32, @intCast(gxScale(transfer.downscale))) << 24);
}

fn gxFormat(format: pica.ColorFormat) c_int {
    return switch (format) {
        .abgr8888 => c.GX_TRANSFER_FMT_RGBA8,
        .bgr888 => c.GX_TRANSFER_FMT_RGB8,
        .rgb565 => c.GX_TRANSFER_FMT_RGB565,
        .rgba5551 => c.GX_TRANSFER_FMT_RGB5A1,
        .rgba4444 => c.GX_TRANSFER_FMT_RGBA4,
    };
}

fn gxScale(scale: pica.PictureFormatter.Flags.Downscale) c_int {
    return switch (scale) {
        .none => c.GX_TRANSFER_SCALE_NO,
        .@"2x1" => c.GX_TRANSFER_SCALE_X,
        .@"2x2" => c.GX_TRANSFER_SCALE_XY,
    };
}

const page_size = 0x1000;

const AetherCtru = @This();

const std = @import("std");
const zitrus = @import("zitrus");
const mango = zitrus.mango;
const pica = zitrus.hardware.pica;
const backend = @import("../backend.zig");

const Device = backend.Device;
const Queue = backend.Queue;
const CommandBuffer = backend.CommandBuffer;

const c = @cImport({
    @cDefine("wint_t", "unsigned int");
    @cInclude("3ds/types.h");
    @cInclude("3ds/gpu/gx.h");
    @cInclude("3ds/os.h");
    @cInclude("3ds/services/gspgpu.h");
    @cInclude("3ds/allocator/vram.h");
});
