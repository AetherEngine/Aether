const std = @import("std");
const surface_api = @import("../surface.zig");
const zitrus = @import("zitrus");
const app_3ds = @import("app.zig");
const Self = @This();

const horizon = zitrus.horizon;
const mango = zitrus.mango;
const GraphicsServerGpu = horizon.services.GraphicsServerGpu;

const VIRTUAL_WIDTH = 400;
const VIRTUAL_HEIGHT = 240;
const SWAP_IMAGE_COUNT = 2;
const COLOR_FORMAT = mango.Format.b8g8r8_unorm;
const COLOR_BYTES_PER_PIXEL = 4;
const ACQUIRE_TIMEOUT_NS = 2 * std.time.ns_per_s;

pub const Screen = enum {
    top,
    bottom,
};

const DisplayState = struct {
    display: mango.Display,
    width: u16,
    height: u16,
    memory: []const u8 = &.{},
    memory_infos: [SWAP_IMAGE_COUNT]mango.DeviceSlice = @splat(.empty),
    images: [SWAP_IMAGE_COUNT]mango.Image = @splat(.null),
    image_index: u8 = 0,
    image_count: u8 = 0,
    acquired: bool = false,
};

alloc: std.mem.Allocator,
device: mango.Device = .null,
// NOTE: Top display wide mode (240x800) is supported by the device IFF it is not an o2DS
top: DisplayState = .{ .display = .top, .width = 240, .height = 400 },
bottom: DisplayState = .{ .display = .bottom, .width = 240, .height = 320 },
sync: bool = true,
applet_released: bool = false,
last_capture: ?GraphicsServerGpu.ScreenCapture = null,

pub fn init(self: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, sync: bool, _: bool) surface_api.InitError!void {
    const app = app_3ds.currentApplication() orelse return error.SurfaceInitFailed;

    self.sync = sync;
    self.device = mango.createHorizonBackedDevice(.{
        .gsp = app.gsp,
        .arbiter = app.base.arbiter,
    }, self.alloc) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SurfaceInitFailed,
    };
    errdefer {
        self.device.destroy();
        self.device = .null;
    }

    self.init_swapchains() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SurfaceInitFailed,
    };
}

pub fn deinit(self: *Self) void {
    if (self.device == .null) return;

    const closing = self.is_system_closing();
    if (self.applet_released and !closing) self.resume_from_applet();

    self.device.waitIdle();
    self.deinit_display(&self.bottom);
    self.deinit_display(&self.top);
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

pub fn set_vsync(self: *Self, sync: bool) !void {
    if (self.sync == sync) return;
    if (self.device == .null) {
        self.sync = sync;
        return;
    }

    self.device.waitIdle();

    const old_sync = self.sync;

    self.deinit_display(&self.bottom);
    self.deinit_display(&self.top);
    self.sync = sync;

    self.init_swapchains() catch |err| {
        self.sync = old_sync;
        self.top = .{ .display = .top, .width = 240, .height = 400 };
        self.bottom = .{ .display = .bottom, .width = 240, .height = 320 };
        self.init_swapchains() catch |restore_err| {
            std.log.err("3DS Mango swapchain restore failed after vsync toggle: {s}", .{@errorName(restore_err)});
        };
        return err;
    };
}

fn init_swapchains(self: *Self) !void {
    try self.init_display(&self.top);
    errdefer self.deinit_display(&self.top);
    try self.init_display(&self.bottom);
}

pub fn get_width(_: *Self) u32 {
    return VIRTUAL_WIDTH;
}

pub fn get_height(_: *Self) u32 {
    return VIRTUAL_HEIGHT;
}

pub fn acquire(self: *Self, which: Screen) !void {
    const chain = self.screen(which);
    if (chain.acquired) return;
    chain.image_index = self.device.acquireNextImage(chain.display, ACQUIRE_TIMEOUT_NS) catch |err| {
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

pub fn present(self: *Self, which: Screen, wait_value: u64, wait_semaphore: mango.Semaphore) !void {
    const chain = self.screen(which);
    if (!chain.acquired) return;

    const wait_op: ?mango.SemaphoreQueueOperation = if (wait_value == 0)
        null
    else
        .init(wait_semaphore, wait_value);

    try self.device.present(if (wait_op) |*op| op else null, &.{
        .display = chain.display,
        .image_index = chain.image_index,
        .flags = .{ .ignore_stereoscopic = true },
    });
    chain.acquired = false;
}

fn screen(self: *Self, which: Screen) *DisplayState {
    return switch (which) {
        .top => &self.top,
        .bottom => &self.bottom,
    };
}

fn init_display(self: *Self, state: *DisplayState) !void {
    const bytes_per_image = @as(u32, state.width) * @as(u32, state.height) * COLOR_BYTES_PER_PIXEL;
    const fcram = self.device.hostAllocator();

    state.memory = try fcram.alloc(u8, SWAP_IMAGE_COUNT * bytes_per_image);
    errdefer fcram.free(state.memory);

    const gpu_display_memory = try self.device.hostToDevice(state.memory);

    for (&state.memory_infos, 0..) |*info, i| {
        info.* = gpu_display_memory.openSlice(i * bytes_per_image);
    }

    try self.device.configureDisplay(state.display, &.{
        .extent = .{ .width = state.width, .height = state.height },
        .present_mode = if (self.sync) .fifo else .mailbox,
        .image_format = COLOR_FORMAT,
        .image_array_layers = .@"1",
        .image_count = SWAP_IMAGE_COUNT,
        .image_memory = &state.memory_infos,
    });
    errdefer self.device.resetDisplay(state.display);

    state.image_count = try self.device.getDisplayImages(state.display, &state.images);
}

fn deinit_display(self: *Self, state: *DisplayState) void {
    self.device.resetDisplay(state.display);

    const fcram = self.device.hostAllocator();
    fcram.free(state.memory);
    state.memory = &.{};

    state.images = @splat(.null);
    state.image_count = 0;
    state.image_index = 0;
    state.acquired = false;
}
