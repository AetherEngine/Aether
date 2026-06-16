const gfx = @import("../gfx.zig");
const Util = @import("../../util/util.zig");
const logger = @import("../../util/logger.zig");
const dk = @import("deko.zig");
const Context = @import("context.zig");
const GarbageCollector = @import("garbage_collector.zig");

pub const FB_COUNT = 2;
pub const MAX_FRAMES = 3;
const CMD_MEM_SIZE = 16 * 1024 * 1024;
const STATIC_CMD_MEM_SIZE = 64 * 1024;
const USE_PRESENT_IMAGE_COMPRESSION = false;

pub const PresentState = enum {
    optimal,
    suboptimal,
};

const Frame = struct {
    fence: dk.DkFence = dk.emptyFence(),
    submitted: bool = false,
};

context: *Context,
chain: dk.DkSwapchain = null,
framebuffer_mems: [FB_COUNT]dk.DkMemBlock = @splat(null),
framebuffers: [FB_COUNT]dk.DkImage = undefined,
framebuffer_views: [FB_COUNT]dk.DkImageView = undefined,
depth_mem: dk.DkMemBlock = null,
depth_image: dk.DkImage = undefined,
depth_view: dk.DkImageView = undefined,
static_command_mem: dk.DkMemBlock = null,
static_command_buffer: dk.DkCmdBuf = null,
framebuffer_cmdlists: [FB_COUNT]dk.DkCmdList = @splat(0),
command_mem: dk.DkMemBlock = null,
command_buffer: dk.DkCmdBuf = null,
frames: [MAX_FRAMES]Frame = @splat(.{}),
frame_index: usize = 0,
image_index: usize = 0,
width: u32 = 0,
height: u32 = 0,
vsync: bool = true,
recording: bool = false,
trace_frames_remaining: u32 = 0,
startup_wait_frames_remaining: u32 = 0,

const Self = @This();

fn trace(self: *const Self, comptime format: []const u8, args: anytype) void {
    if (self.trace_frames_remaining == 0) return;
    Util.engine_logger.err(format, args);
    logger.flush();
}

pub fn init(context: *Context, vsync: bool) !Self {
    var self = Self{ .context = context, .vsync = vsync };
    try self.createFramebuffers();
    errdefer self.destroyFramebuffers();
    try self.createDepthImage();
    errdefer self.destroyDepthImage();
    try self.createFramebufferCommandLists();
    errdefer self.destroyFramebufferCommandLists();
    try self.createCommandBuffer();
    errdefer self.destroyCommandBuffer();
    self.setVsync(vsync);
    return self;
}

pub fn deinit(self: *Self) void {
    self.context.waitIdle("switch swapchain deinit");
    self.destroyCommandBuffer();
    self.destroyFramebufferCommandLists();
    self.destroyDepthImage();
    self.destroyFramebuffers();
}

pub fn beginFrame(self: *Self, gc: *GarbageCollector) bool {
    self.trace("Switch swapchain beginFrame: enter frame={d}", .{self.frame_index});
    if (gfx.surface.get_width() == 0 or gfx.surface.get_height() == 0) return false;
    if (self.chain == null or self.command_buffer == null or self.command_mem == null or self.static_command_buffer == null) return false;
    self.resizeIfNeeded() catch return false;

    const frame = &self.frames[self.frame_index];
    var was_submitted = false;
    if (frame.submitted) {
        self.trace("Switch swapchain beginFrame: wait prior fence begin frame={d}", .{self.frame_index});
        self.context.waitFence(&frame.fence, "switch frame fence");
        self.trace("Switch swapchain beginFrame: wait prior fence end frame={d}", .{self.frame_index});
        frame.submitted = false;
        was_submitted = true;
    }
    gc.retireFrame(self.frame_index, was_submitted);
    self.limitSubmittedFrames(gc, 0);

    self.trace("Switch swapchain beginFrame: acquire begin", .{});
    const slot = dk.dkQueueAcquireImage(self.context.queue, self.chain);
    self.trace("Switch swapchain beginFrame: acquire end slot={d}", .{slot});
    self.context.assertQueueOk("acquire image");
    if (slot < 0 or slot >= FB_COUNT) return false;
    self.image_index = @intCast(slot);
    if (self.framebuffer_cmdlists[self.image_index] == 0) return false;

    self.trace("Switch swapchain beginFrame: command setup begin image={d}", .{self.image_index});
    dk.dkCmdBufClear(self.command_buffer);
    dk.dkCmdBufAddMemory(
        self.command_buffer,
        self.command_mem,
        @intCast(self.frame_index * CMD_MEM_SIZE),
        CMD_MEM_SIZE,
    );
    dk.dkCmdBufCallList(self.command_buffer, self.framebuffer_cmdlists[self.image_index]);
    self.trace("Switch swapchain beginFrame: command setup end", .{});
    self.recording = true;
    return true;
}

pub fn bindRenderTargetsAndClear(self: *Self, clear_color: *const [4]f32) void {
    const width = gfx.surface.get_width();
    const height = gfx.surface.get_height();
    var viewport = dk.DkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .near = 0.0,
        .far = 1.0,
    };
    var scissor = dk.DkScissor{
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    };
    dk.dkCmdBufSetViewports(self.command_buffer, 0, @ptrCast(&viewport), 1);
    dk.dkCmdBufSetScissors(self.command_buffer, 0, @ptrCast(&scissor), 1);
    var color_write = dk.DkColorWriteState{ .masks = 0xFFFF_FFFF };
    dk.dkCmdBufBindColorWriteState(self.command_buffer, &color_write);
    dk.dkCmdBufClearColor(self.command_buffer, 0, dk.ColorMaskRgba, clear_color);
    dk.dkCmdBufClearDepthStencil(self.command_buffer, true, 1.0, 0xFF, 0);
    self.context.markCpu(.frame_clear, @intCast(self.frame_index), @intCast(self.image_index), width, height);
    self.context.markGpu(self.command_buffer, .frame_clear);
}

pub fn endFrame(self: *Self) PresentState {
    if (!self.recording or self.chain == null or self.command_buffer == null) return .optimal;

    self.trace("Switch swapchain endFrame: finish begin frame={d} image={d}", .{ self.frame_index, self.image_index });
    self.context.markCpu(.frame_before_submit, @intCast(self.frame_index), @intCast(self.image_index), 0, 0);
    self.context.markGpu(self.command_buffer, .frame_before_submit);
    dk.dkCmdBufBarrier(self.command_buffer, dk.BarrierFragments, 0);
    dk.dkCmdBufDiscardDepthStencil(self.command_buffer);
    dk.dkCmdBufSignalFence(self.command_buffer, &self.frames[self.frame_index].fence, true);
    const list = dk.dkCmdBufFinishList(self.command_buffer);
    if (list == 0) Context.panicGpu("deko3d failed to finish frame command list", .{});
    self.trace("Switch swapchain endFrame: finish end list=0x{x}", .{list});
    self.trace("Switch swapchain endFrame: submit begin", .{});
    dk.dkQueueSubmitCommands(self.context.queue, list);
    self.trace("Switch swapchain endFrame: submit end", .{});
    self.context.markCpu(.frame_submitted, @intCast(self.frame_index), @intCast(self.image_index), 0, 0);
    self.context.assertQueueOk("submit frame");
    if (self.startup_wait_frames_remaining > 0) {
        self.trace("Switch swapchain endFrame: startup render wait begin", .{});
        self.context.flushQueue("startup frame render flush");
        self.context.waitFence(&self.frames[self.frame_index].fence, "startup frame render fence");
        self.trace("Switch swapchain endFrame: startup render wait end", .{});
        self.startup_wait_frames_remaining -= 1;
    }
    self.trace("Switch swapchain endFrame: present begin image={d}", .{self.image_index});
    dk.dkQueuePresentImage(self.context.queue, self.chain, @intCast(self.image_index));
    self.trace("Switch swapchain endFrame: present end", .{});
    self.context.markCpu(.frame_presented, @intCast(self.frame_index), @intCast(self.image_index), 0, 0);
    self.context.assertQueueOk("present image");
    self.frames[self.frame_index].submitted = true;
    self.frame_index = (self.frame_index + 1) % MAX_FRAMES;
    self.recording = false;
    if (self.trace_frames_remaining > 0) self.trace_frames_remaining -= 1;
    return .optimal;
}

pub fn pendingFrameMask(self: *const Self) u32 {
    var mask: u32 = 0;
    for (self.frames, 0..) |frame, i| {
        if (frame.submitted) mask |= @as(u32, 1) << @intCast(i);
    }
    if (self.recording) mask |= @as(u32, 1) << @intCast(self.frame_index);
    return mask;
}

pub fn setVsync(self: *Self, enabled: bool) void {
    self.vsync = enabled;
    if (self.chain) |chain| dk.dkSwapchainSetSwapInterval(chain, @intFromBool(enabled));
}

fn limitSubmittedFrames(self: *Self, gc: *GarbageCollector, max_submitted: u32) void {
    while (self.submittedFrameCount() > max_submitted) {
        if (!self.waitOldestSubmittedFrame(gc)) return;
    }
}

fn submittedFrameCount(self: *const Self) u32 {
    var count: u32 = 0;
    for (self.frames) |frame| {
        if (frame.submitted) count += 1;
    }
    return count;
}

fn waitOldestSubmittedFrame(self: *Self, gc: *GarbageCollector) bool {
    var offset: usize = 0;
    while (offset < MAX_FRAMES) : (offset += 1) {
        const index = (self.frame_index + offset) % MAX_FRAMES;
        const frame = &self.frames[index];
        if (!frame.submitted) continue;
        self.trace("Switch swapchain beginFrame: throttle wait begin frame={d}", .{index});
        self.context.waitFence(&frame.fence, "switch vsync-off throttle fence");
        self.trace("Switch swapchain beginFrame: throttle wait end frame={d}", .{index});
        frame.submitted = false;
        gc.retireFrame(index, true);
        return true;
    }
    return false;
}

fn resizeIfNeeded(self: *Self) !void {
    const width = gfx.surface.get_width();
    const height = gfx.surface.get_height();
    if (width == self.width and height == self.height) return;

    self.context.waitIdle("switch swapchain resize");
    self.frames = @splat(.{});
    self.frame_index = 0;
    self.image_index = 0;
    self.recording = false;

    self.destroyFramebufferCommandLists();
    self.destroyDepthImage();
    self.destroyFramebuffers();

    try self.createFramebuffers();
    errdefer self.destroyFramebuffers();
    try self.createDepthImage();
    errdefer self.destroyDepthImage();
    try self.createFramebufferCommandLists();
    self.setVsync(self.vsync);
}

fn createFramebuffers(self: *Self) !void {
    const width = gfx.surface.get_width();
    const height = gfx.surface.get_height();
    const native_window = try self.configureNativeWindow(width, height);
    var layout_maker = dk.DkImageLayoutMaker{
        .device = self.context.device,
        .type = dk.ImageType2d,
        .flags = dk.ImageUsageRender | dk.ImageUsagePresent |
            if (USE_PRESENT_IMAGE_COMPRESSION) dk.ImageHwCompression else 0,
        .format = dk.ImageRgba8Unorm,
        .msMode = 0,
        .dimensions = .{ width, height, 0 },
        .mipLevels = 1,
        .pitchStride = 0,
    };

    var framebuffer_layout: dk.DkImageLayout = undefined;
    dk.dkImageLayoutInitialize(&framebuffer_layout, &layout_maker);

    const fb_size: u32 = @intCast(dk.dkImageLayoutGetSize(&framebuffer_layout));

    var swapchain_images: [FB_COUNT]*const dk.DkImage = undefined;
    for (&self.framebuffers, 0..) |*fb, i| {
        self.framebuffer_mems[i] = try self.context.createMemBlock(fb_size, dk.MemGpuCached | dk.MemImage);
        errdefer {
            dk.dkMemBlockDestroy(self.framebuffer_mems[i]);
            self.framebuffer_mems[i] = null;
        }
        dk.dkImageInitialize(fb, &framebuffer_layout, self.framebuffer_mems[i], 0);
        self.framebuffer_views[i] = dk.imageView(fb);
        swapchain_images[i] = fb;
    }

    var swapchain_maker = dk.DkSwapchainMaker{
        .device = self.context.device,
        .nativeWindow = native_window,
        .pImages = swapchain_images[0..].ptr,
        .numImages = FB_COUNT,
    };
    self.chain = dk.dkSwapchainCreate(&swapchain_maker);
    if (self.chain == null) return error.GfxInitFailed;
    self.width = width;
    self.height = height;
}

fn destroyFramebuffers(self: *Self) void {
    if (self.chain) |_| {
        dk.dkSwapchainDestroy(self.chain);
        self.chain = null;
    }
    for (&self.framebuffer_mems) |*mem| {
        if (mem.*) |_| {
            dk.dkMemBlockDestroy(mem.*);
            mem.* = null;
        }
    }
    self.width = 0;
    self.height = 0;
}

fn configureNativeWindow(self: *Self, width: u32, height: u32) !*anyopaque {
    const native_window = dk.nwindowGetDefault() orelse return error.GfxInitFailed;
    var rc = dk.nwindowSetDimensions(native_window, width, height);
    if (rc != 0) {
        _ = dk.nwindowReleaseBuffers(native_window);
        rc = dk.nwindowSetDimensions(native_window, width, height);
    }
    if (rc != 0) {
        Util.engine_logger.err("Switch nwindowSetDimensions failed: {d} for {d}x{d}", .{ rc, width, height });
        return error.GfxInitFailed;
    }
    self.trace("Switch swapchain native window dimensions set: {d}x{d}", .{ width, height });
    return native_window;
}

fn createDepthImage(self: *Self) !void {
    const width = gfx.surface.get_width();
    const height = gfx.surface.get_height();
    var layout_maker = dk.DkImageLayoutMaker{
        .device = self.context.device,
        .type = dk.ImageType2d,
        .flags = dk.ImageUsageRender,
        .format = dk.ImageZ24S8,
        .msMode = 0,
        .dimensions = .{ width, height, 0 },
        .mipLevels = 1,
        .pitchStride = 0,
    };

    var depth_layout: dk.DkImageLayout = undefined;
    dk.dkImageLayoutInitialize(&depth_layout, &layout_maker);
    const depth_align = dk.dkImageLayoutGetAlignment(&depth_layout);
    const depth_size = dk.alignForward(@intCast(dk.dkImageLayoutGetSize(&depth_layout)), depth_align);
    self.depth_mem = try self.context.createMemBlock(depth_size, dk.MemGpuCached | dk.MemImage);
    dk.dkImageInitialize(&self.depth_image, &depth_layout, self.depth_mem, 0);
    self.depth_view = dk.imageView(&self.depth_image);
}

fn destroyDepthImage(self: *Self) void {
    if (self.depth_mem) |_| {
        dk.dkMemBlockDestroy(self.depth_mem);
        self.depth_mem = null;
    }
}

fn createFramebufferCommandLists(self: *Self) !void {
    self.static_command_mem = try self.context.createMemBlock(STATIC_CMD_MEM_SIZE, dk.MemCpuUncached | dk.MemGpuCached);
    errdefer {
        dk.dkMemBlockDestroy(self.static_command_mem);
        self.static_command_mem = null;
    }

    var cmd_maker = dk.DkCmdBufMaker{
        .device = self.context.device,
        .userData = null,
        .cbAddMem = null,
    };
    self.static_command_buffer = dk.dkCmdBufCreate(&cmd_maker);
    if (self.static_command_buffer == null) return error.GfxInitFailed;
    errdefer {
        dk.dkCmdBufDestroy(self.static_command_buffer);
        self.static_command_buffer = null;
    }

    dk.dkCmdBufAddMemory(self.static_command_buffer, self.static_command_mem, 0, STATIC_CMD_MEM_SIZE);
    for (&self.framebuffer_views, 0..) |*color_view, i| {
        const color_targets = [_]*const dk.DkImageView{color_view};
        dk.dkCmdBufBindRenderTargets(self.static_command_buffer, color_targets[0..].ptr, 1, &self.depth_view);
        self.framebuffer_cmdlists[i] = dk.dkCmdBufFinishList(self.static_command_buffer);
        if (self.framebuffer_cmdlists[i] == 0) return error.GfxInitFailed;
    }
}

fn destroyFramebufferCommandLists(self: *Self) void {
    self.framebuffer_cmdlists = @splat(0);
    if (self.static_command_buffer) |_| {
        dk.dkCmdBufDestroy(self.static_command_buffer);
        self.static_command_buffer = null;
    }
    if (self.static_command_mem) |_| {
        dk.dkMemBlockDestroy(self.static_command_mem);
        self.static_command_mem = null;
    }
}

fn createCommandBuffer(self: *Self) !void {
    self.command_mem = try self.context.createMemBlock(CMD_MEM_SIZE * MAX_FRAMES, dk.MemCpuUncached | dk.MemGpuCached);
    errdefer {
        dk.dkMemBlockDestroy(self.command_mem);
        self.command_mem = null;
    }

    var cmd_maker = dk.DkCmdBufMaker{
        .device = self.context.device,
        .userData = null,
        .cbAddMem = null,
    };
    self.command_buffer = dk.dkCmdBufCreate(&cmd_maker);
    if (self.command_buffer == null) return error.GfxInitFailed;
}

fn destroyCommandBuffer(self: *Self) void {
    if (self.command_buffer) |_| {
        dk.dkCmdBufDestroy(self.command_buffer);
        self.command_buffer = null;
    }
    if (self.command_mem) |_| {
        dk.dkMemBlockDestroy(self.command_mem);
        self.command_mem = null;
    }
}
