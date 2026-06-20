const std = @import("std");
const zitrus = @import("zitrus");
const app_3ds = @import("app.zig");
const Self = @This();

const horizon = zitrus.horizon;
const mango = zitrus.mango;
const GraphicsServerGpu = horizon.services.GraphicsServerGpu;

const VIRTUAL_WIDTH = 400;
const VIRTUAL_HEIGHT = 240;
const SWAP_IMAGE_COUNT = 2;
const COLOR_FORMAT = mango.Format.a8b8g8r8_unorm;
const COLOR_BYTES_PER_PIXEL = 4;
const ACQUIRE_TIMEOUT_NS = 2 * std.time.ns_per_s;

pub const Screen = enum {
    top,
    bottom,
};

const SwapchainState = struct {
    surface: mango.Surface,
    swapchain: mango.Swapchain = .null,
    memories: [SWAP_IMAGE_COUNT]mango.DeviceMemory = @splat(.null),
    memory_infos: [SWAP_IMAGE_COUNT]mango.SwapchainCreateInfo.ImageMemoryInfo = undefined,
    images: [SWAP_IMAGE_COUNT]mango.Image = @splat(.null),
    views: [SWAP_IMAGE_COUNT]mango.ImageView = @splat(.null),
    image_index: u8 = 0,
    image_count: u8 = 0,
    acquired: bool = false,

    fn dimensions(state: SwapchainState) struct { width: u16, height: u16 } {
        return switch (state.surface) {
            .top_240x400 => .{ .width = 240, .height = 400 },
            .bottom_240x320 => .{ .width = 240, .height = 320 },
            .top_240x800 => .{ .width = 240, .height = 800 },
            else => unreachable,
        };
    }
};

alloc: std.mem.Allocator,
device: mango.Device = .null,
queues: std.EnumArray(mango.QueueFamily, mango.Queue) = .initFill(.null),
top: SwapchainState = .{ .surface = .top_240x800 },
bottom: SwapchainState = .{ .surface = .bottom_240x320 },
sync: bool = true,
applet_released: bool = false,
last_capture: ?GraphicsServerGpu.ScreenCapture = null,

pub fn init(self: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, sync: bool, _: bool) anyerror!void {
    const app = app_3ds.currentApplication() orelse return error.NoCurrentApplication;

    self.sync = sync;
    self.device = try mango.createHorizonBackedDevice(.{
        .gsp = app.gsp,
        .arbiter = app.base.arbiter,
    }, self.alloc);
    errdefer {
        self.device.destroy();
        self.device = .null;
    }

    for (std.enums.values(mango.QueueFamily)) |family| {
        self.queues.set(family, self.device.getQueue(family));
    }

    try self.init_swapchain(&self.top);
    errdefer self.deinit_swapchain(&self.top);

    try self.init_swapchain(&self.bottom);
    errdefer self.deinit_swapchain(&self.bottom);
}

pub fn deinit(self: *Self) void {
    if (self.device == .null) return;

    const closing = self.is_system_closing();
    if (self.applet_released and !closing) self.resume_from_applet();

    self.device.waitIdle();
    self.deinit_swapchain(&self.bottom);
    self.deinit_swapchain(&self.top);
    self.device.destroy();
    self.device = .null;
    self.applet_released = false;
    self.last_capture = null;
}

pub fn is_system_closing(_: *const Self) bool {
    const app = app_3ds.currentApplication() orelse return true;
    return app.app.flags.must_close;
}

pub fn suspend_for_applet(self: *Self) !GraphicsServerGpu.ScreenCapture {
    if (self.device == .null) return error.GraphicsNotInitialized;
    if (self.applet_released) return self.last_capture orelse error.GraphicsNotInitialized;

    const capture = try self.device.release();
    self.last_capture = capture;
    self.applet_released = true;
    return capture;
}

pub fn resume_from_applet(self: *Self) void {
    if (!self.applet_released or self.device == .null) return;

    self.device.reacquire() catch |err| {
        std.log.err("3DS Mango device reacquire failed: {s}", .{@errorName(err)});
        return;
    };
    self.applet_released = false;
    self.last_capture = null;
}

pub fn update(_: *Self) bool {
    return true;
}

pub fn draw(_: *Self) void {}

pub fn get_width(_: *Self) u32 {
    return VIRTUAL_WIDTH;
}

pub fn get_height(_: *Self) u32 {
    return VIRTUAL_HEIGHT;
}

pub fn acquire(self: *Self, which: Screen) !void {
    const chain = self.screen(which);
    if (chain.acquired) return;
    chain.image_index = self.device.acquireNextImage(chain.swapchain, ACQUIRE_TIMEOUT_NS) catch |err| {
        std.log.err("3DS Mango swapchain acquire stalled: screen={}", .{which});
        return err;
    };
    chain.acquired = true;
}

pub fn current_image(self: *Self, which: Screen) mango.Image {
    const chain = self.screen(which);
    std.debug.assert(chain.acquired);
    return chain.images[chain.image_index];
}

pub fn current_view(self: *Self, which: Screen) mango.ImageView {
    const chain = self.screen(which);
    std.debug.assert(chain.acquired);
    return chain.views[chain.image_index];
}

pub fn present(self: *Self, which: Screen, wait_value: u64, wait_semaphore: mango.Semaphore) !void {
    const chain = self.screen(which);
    if (!chain.acquired) return;

    const wait_op: ?mango.SemaphoreQueueOperation = if (wait_value == 0)
        null
    else
        .init(wait_semaphore, wait_value);

    try self.queues.get(.present).present(.{
        .wait_semaphore = if (wait_op) |*op| op else null,
        .swapchain = chain.swapchain,
        .image_index = chain.image_index,
        .flags = .{ .ignore_stereoscopic = true },
    });
    chain.acquired = false;
}

fn screen(self: *Self, which: Screen) *SwapchainState {
    return switch (which) {
        .top => &self.top,
        .bottom => &self.bottom,
    };
}

fn init_swapchain(self: *Self, chain: *SwapchainState) !void {
    const dims = chain.dimensions();
    const bytes_per_image = @as(u32, dims.width) * @as(u32, dims.height) * COLOR_BYTES_PER_PIXEL;

    for (0..SWAP_IMAGE_COUNT) |i| {
        const memory = try self.device.allocateMemory(.{
            .allocation_size = .size(bytes_per_image),
            .memory_type = .fcram_cached,
        }, null);
        errdefer self.device.freeMemory(memory, null);

        chain.memories[i] = memory;
        chain.memory_infos[i] = .{
            .memory = memory,
            .memory_offset = .size(0),
        };
    }
    errdefer for (chain.memories) |memory| {
        if (memory != .null) self.device.freeMemory(memory, null);
    };

    chain.swapchain = try self.device.createSwapchain(.{
        .surface = chain.surface,
        .present_mode = if (self.sync) .fifo else .mailbox,
        .image_usage = .{
            .transfer_dst = true,
            .color_attachment = true,
        },
        .image_format = COLOR_FORMAT,
        .image_array_layers = .@"1",
        .image_count = SWAP_IMAGE_COUNT,
        .image_memory_info = &chain.memory_infos,
    }, null);
    errdefer {
        self.device.destroySwapchain(chain.swapchain, null);
        chain.swapchain = .null;
    }

    chain.image_count = try self.device.getSwapchainImages(chain.swapchain, &chain.images);
    errdefer for (&chain.views) |*view| {
        if (view.* != .null) {
            self.device.destroyImageView(view.*, null);
            view.* = .null;
        }
    };

    for (chain.images[0..chain.image_count], 0..) |image, i| {
        chain.views[i] = try self.device.createImageView(.{
            .type = .@"2d",
            .format = COLOR_FORMAT,
            .image = image,
            .subresource_range = .full,
        }, null);
    }
}

fn deinit_swapchain(self: *Self, chain: *SwapchainState) void {
    for (&chain.views) |*view| {
        if (view.* != .null) {
            self.device.destroyImageView(view.*, null);
            view.* = .null;
        }
    }

    if (chain.swapchain != .null) {
        self.device.destroySwapchain(chain.swapchain, null);
        chain.swapchain = .null;
    }

    for (&chain.memories) |*memory| {
        if (memory.* != .null) {
            self.device.freeMemory(memory.*, null);
            memory.* = .null;
        }
    }

    chain.images = @splat(.null);
    chain.views = @splat(.null);
    chain.image_count = 0;
    chain.image_index = 0;
    chain.acquired = false;
}
