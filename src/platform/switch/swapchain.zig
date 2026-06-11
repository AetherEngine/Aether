const std = @import("std");
const gfx = @import("../gfx.zig");
const dk = @import("deko.zig");
const Context = @import("context.zig");
const GarbageCollector = @import("garbage_collector.zig");

pub const FB_COUNT = 2;
pub const FB_WIDTH = 1280;
pub const FB_HEIGHT = 720;
pub const MAX_FRAMES = 3;
const CMD_MEM_SIZE = 1024 * 1024;
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
depth_mem: dk.DkMemBlock = null,
depth_image: dk.DkImage = undefined,
static_command_mem: dk.DkMemBlock = null,
static_command_buffer: dk.DkCmdBuf = null,
framebuffer_cmdlists: [FB_COUNT]dk.DkCmdList = @splat(0),
command_mem: dk.DkMemBlock = null,
command_buffer: dk.DkCmdBuf = null,
frames: [MAX_FRAMES]Frame = @splat(.{}),
frame_index: usize = 0,
image_index: usize = 0,
vsync: bool = true,
recording: bool = false,

const Self = @This();

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
    if (gfx.surface.get_width() == 0 or gfx.surface.get_height() == 0) return false;
    if (self.chain == null or self.command_buffer == null or self.command_mem == null or self.static_command_buffer == null) return false;

    const frame = &self.frames[self.frame_index];
    var was_submitted = false;
    if (frame.submitted) {
        self.context.waitFence(&frame.fence, "switch frame fence");
        frame.submitted = false;
        was_submitted = true;
    }
    gc.retireFrame(self.frame_index, was_submitted);

    const slot = dk.dkQueueAcquireImage(self.context.queue, self.chain);
    self.context.assertQueueOk("acquire image");
    if (slot < 0 or slot >= FB_COUNT) return false;
    self.image_index = @intCast(slot);
    if (self.framebuffer_cmdlists[self.image_index] == 0) return false;

    dk.dkCmdBufClear(self.command_buffer);
    dk.dkCmdBufAddMemory(
        self.command_buffer,
        self.command_mem,
        @intCast(self.frame_index * CMD_MEM_SIZE),
        CMD_MEM_SIZE,
    );
    dk.dkCmdBufCallList(self.command_buffer, self.framebuffer_cmdlists[self.image_index]);
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
}

pub fn endFrame(self: *Self) PresentState {
    if (!self.recording or self.chain == null or self.command_buffer == null) return .optimal;

    dk.dkCmdBufBarrier(self.command_buffer, dk.BarrierFragments, 0);
    dk.dkCmdBufDiscardDepthStencil(self.command_buffer);
    dk.dkCmdBufSignalFence(self.command_buffer, &self.frames[self.frame_index].fence, true);
    const list = dk.dkCmdBufFinishList(self.command_buffer);
    if (list == 0) std.debug.panic("deko3d failed to finish frame command list", .{});
    dk.dkQueueSubmitCommands(self.context.queue, list);
    self.context.assertQueueOk("submit frame");
    dk.dkQueuePresentImage(self.context.queue, self.chain, @intCast(self.image_index));
    self.context.assertQueueOk("present image");
    self.frames[self.frame_index].submitted = true;
    self.frame_index = (self.frame_index + 1) % MAX_FRAMES;
    self.recording = false;
    return .optimal;
}

pub fn retireGarbageFrame(self: *Self, gc: *GarbageCollector) void {
    if (gc.frame_index >= MAX_FRAMES) return;
    const frame = &self.frames[gc.frame_index];
    var was_submitted = false;
    if (frame.submitted) {
        self.context.waitFence(&frame.fence, "switch resource transition frame fence");
        frame.submitted = false;
        was_submitted = true;
    }
    gc.retireFrame(gc.frame_index, was_submitted);
}

pub fn setVsync(self: *Self, enabled: bool) void {
    self.vsync = enabled;
    if (self.chain) |chain| dk.dkSwapchainSetSwapInterval(chain, @intFromBool(enabled));
}

fn createFramebuffers(self: *Self) !void {
    var layout_maker = dk.DkImageLayoutMaker{
        .device = self.context.device,
        .type = dk.ImageType2d,
        .flags = dk.ImageUsageRender | dk.ImageUsagePresent |
            if (USE_PRESENT_IMAGE_COMPRESSION) dk.ImageHwCompression else 0,
        .format = dk.ImageRgba8Unorm,
        .msMode = 0,
        .dimensions = .{ FB_WIDTH, FB_HEIGHT, 0 },
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
        swapchain_images[i] = fb;
    }

    var swapchain_maker = dk.DkSwapchainMaker{
        .device = self.context.device,
        .nativeWindow = dk.nwindowGetDefault(),
        .pImages = swapchain_images[0..].ptr,
        .numImages = FB_COUNT,
    };
    self.chain = dk.dkSwapchainCreate(&swapchain_maker);
    if (self.chain == null) return error.GfxInitFailed;
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
}

fn createDepthImage(self: *Self) !void {
    var layout_maker = dk.DkImageLayoutMaker{
        .device = self.context.device,
        .type = dk.ImageType2d,
        .flags = dk.ImageUsageRender | dk.ImageHwCompression,
        .format = dk.ImageZ24S8,
        .msMode = 0,
        .dimensions = .{ FB_WIDTH, FB_HEIGHT, 0 },
        .mipLevels = 1,
        .pitchStride = 0,
    };

    var depth_layout: dk.DkImageLayout = undefined;
    dk.dkImageLayoutInitialize(&depth_layout, &layout_maker);
    const depth_align = dk.dkImageLayoutGetAlignment(&depth_layout);
    const depth_size = dk.alignForward(@intCast(dk.dkImageLayoutGetSize(&depth_layout)), depth_align);
    self.depth_mem = try self.context.createMemBlock(depth_size, dk.MemGpuCached | dk.MemImage);
    dk.dkImageInitialize(&self.depth_image, &depth_layout, self.depth_mem, 0);
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
    for (&self.framebuffers, 0..) |*fb, i| {
        var color_view = dk.imageView(fb);
        var depth_view = dk.imageView(&self.depth_image);
        const color_targets = [_]*const dk.DkImageView{&color_view};
        dk.dkCmdBufBindRenderTargets(self.static_command_buffer, color_targets[0..].ptr, 1, &depth_view);
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
