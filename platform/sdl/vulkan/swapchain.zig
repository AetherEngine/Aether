const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan");
const Context = @import("context.zig");

const SwapChain = @This();

pub const frames_in_flight: usize = 3;

pub const PresentState = enum {
    optimal,
    suboptimal,

    pub fn merge(a: PresentState, b: PresentState) PresentState {
        return if (a == .suboptimal or b == .suboptimal) .suboptimal else .optimal;
    }
};

context: *Context,
vsync: bool,
surface_capabilities: vk.SurfaceCapabilitiesKHR = undefined,
chain: vk.SwapchainKHR = .null_handle,
surface_format: vk.SurfaceFormatKHR = undefined,
extent: vk.Extent2D = .{ .width = 0, .height = 0 },
swap_images: []SwapImage = &.{},
next_image_acquired: vk.Semaphore = .null_handle,
image_index: u32 = 0,
has_acquired_image: bool = false,
frame_fences: [frames_in_flight]vk.Fence = @splat(.null_handle),
frame_index: usize = 0,

fn choose_swap_surface_format(self: *SwapChain) !vk.SurfaceFormatKHR {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_unorm,
        .color_space = .srgb_nonlinear_khr,
    };

    const surface_formats = try self.context.instance.getPhysicalDeviceSurfaceFormatsAllocKHR(
        self.context.physical_device,
        self.context.surface,
        self.context.allocator,
    );
    defer self.context.allocator.free(surface_formats);

    for (surface_formats) |sfmt| {
        if (std.meta.eql(sfmt, preferred)) {
            return preferred;
        }
    }

    return surface_formats[0]; // There must always be at least one supported surface format
}

const gfx = @import("../../gfx.zig");
fn choose_swap_extent(capabilities: vk.SurfaceCapabilitiesKHR, drawable: vk.Extent2D) !vk.Extent2D {
    const extent = if (capabilities.current_extent.width != std.math.maxInt(u32))
        capabilities.current_extent
    else
        vk.Extent2D{
            .width = std.math.clamp(drawable.width, capabilities.min_image_extent.width, capabilities.max_image_extent.width),
            .height = std.math.clamp(drawable.height, capabilities.min_image_extent.height, capabilities.max_image_extent.height),
        };
    if (drawable.width == 0 or drawable.height == 0 or extent.width == 0 or extent.height == 0) return error.ZeroExtent;
    return extent;
}

fn choose_present_mode(self: *SwapChain) !vk.PresentModeKHR {
    if (self.vsync) return .fifo_khr;

    const present_modes = try self.context.instance.getPhysicalDeviceSurfacePresentModesAllocKHR(
        self.context.physical_device,
        self.context.surface,
        self.context.allocator,
    );
    defer self.context.allocator.free(present_modes);

    const preferred = [_]vk.PresentModeKHR{
        .mailbox_khr,
        .immediate_khr,
    };

    for (preferred) |mode| {
        if (std.mem.indexOfScalar(vk.PresentModeKHR, present_modes, mode) != null) {
            return mode;
        }
    }

    return .fifo_khr;
}

fn create_swapchain(self: *SwapChain) !void {
    self.surface_capabilities = try self.context.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        self.context.physical_device,
        self.context.surface,
    );

    const surface_format = try self.choose_swap_surface_format();
    const surface_extent = try choose_swap_extent(self.surface_capabilities, .{
        .width = gfx.surface.get_width(),
        .height = gfx.surface.get_height(),
    });
    const present_mode = try self.choose_present_mode();

    // We want triple buffering so...
    var image_count = @max(3, self.surface_capabilities.min_image_count);
    image_count = if (self.surface_capabilities.max_image_count > 0 and image_count > self.surface_capabilities.max_image_count) self.surface_capabilities.max_image_count else image_count;

    const qfi = [_]u32{ self.context.graphics_queue.family, self.context.present_queue.family };
    const sharing_mode: vk.SharingMode = if (self.context.graphics_queue.family != self.context.present_queue.family)
        .concurrent
    else
        .exclusive;

    // Preflight above must succeed before retiring the old chain. In particular,
    // minimizing can report zero extent even while SDL retains the window size.
    try self.context.logical_device.deviceWaitIdle();
    self.destroy_swapchain_images();
    self.context.logical_device.destroySemaphore(self.next_image_acquired, null);
    self.next_image_acquired = .null_handle;
    self.has_acquired_image = false;
    const old_handle = self.chain;
    self.chain = .null_handle;
    // vkCreateSwapchainKHR retires oldSwapchain even when creation fails.
    defer self.context.logical_device.destroySwapchainKHR(old_handle, null);

    const chain = try self.context.logical_device.createSwapchainKHR(&.{
        .surface = self.context.surface,
        .min_image_count = image_count,
        .image_format = surface_format.format,
        .image_color_space = surface_format.color_space,
        .image_extent = surface_extent,
        .image_array_layers = 1,
        .image_usage = .{ .color_attachment_bit = true, .transfer_dst_bit = true },
        .image_sharing_mode = sharing_mode,
        .pre_transform = self.surface_capabilities.current_transform,
        .composite_alpha = .{ .opaque_bit_khr = true },
        .present_mode = present_mode,
        .clipped = .true,
        .queue_family_index_count = qfi.len,
        .p_queue_family_indices = &qfi,
        .old_swapchain = old_handle,
    }, null);
    errdefer self.context.logical_device.destroySwapchainKHR(chain, null);
    const images = try self.create_swapchain_images(chain, surface_format.format);
    errdefer {
        for (images) |si| si.deinit(self.context);
        self.context.allocator.free(images);
    }
    const acquired = try self.context.logical_device.createSemaphore(&.{}, null);

    // Publish only a complete replacement. On failure the chain stays null and
    // the next frame can retry without dangling views or a retired old handle.
    self.chain = chain;
    self.swap_images = images;
    self.next_image_acquired = acquired;
    self.surface_format = surface_format;
    self.extent = surface_extent;
}

fn acquired_state(result: vk.Result) ?PresentState {
    return switch (result) {
        .success => .optimal,
        .suboptimal_khr => .suboptimal,
        .not_ready, .timeout => null,
        else => unreachable,
    };
}

pub fn acquire(self: *SwapChain) !?PresentState {
    assert(!self.has_acquired_image);
    const timeout_ns: u64 = 100_000_000;
    const result = try self.context.logical_device.acquireNextImageKHR(self.chain, timeout_ns, self.next_image_acquired, .null_handle);
    const state = acquired_state(result.result) orelse return null;
    std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
    self.image_index = result.image_index;
    self.has_acquired_image = true;
    return state;
}

fn destroy_swapchain_images(self: *SwapChain) void {
    for (self.swap_images) |si| si.deinit(self.context);
    self.context.allocator.free(self.swap_images);
    self.swap_images = &.{};
}

fn create_swapchain_images(self: *SwapChain, chain: vk.SwapchainKHR, format: vk.Format) ![]SwapImage {
    const images = try self.context.logical_device.getSwapchainImagesAllocKHR(chain, self.context.allocator);
    defer self.context.allocator.free(images);

    const swap_images = try self.context.allocator.alloc(SwapImage, images.len);
    errdefer self.context.allocator.free(swap_images);

    var i: usize = 0;
    errdefer for (swap_images[0..i]) |si| si.deinit(self.context);

    for (images) |image| {
        swap_images[i] = try SwapImage.init(self.context, image, format);
        i += 1;
    }

    return swap_images;
}

pub fn init(context: *Context, vsync: bool) !SwapChain {
    var self: SwapChain = .{ .context = context, .vsync = vsync };
    try self.create_frame_fences();
    errdefer self.destroy_frame_fences();
    try self.create_swapchain();
    return self;
}

pub fn recreate(self: *SwapChain) !void {
    try self.create_swapchain();
}

pub fn deinit(self: *SwapChain) void {
    defer self.* = undefined;

    self.destroy_frame_fences();
    self.destroy_swapchain_images();
    self.context.logical_device.destroySemaphore(self.next_image_acquired, null);
    self.context.logical_device.destroySwapchainKHR(self.chain, null);
}

pub fn current_image(self: *SwapChain) vk.Image {
    return self.swap_images[self.image_index].image;
}

pub fn current_swap_image(self: *SwapChain) *const SwapImage {
    return &self.swap_images[self.image_index];
}

pub fn wait_for_current_frame(self: *SwapChain) !void {
    const fence = self.frame_fences[self.frame_index];
    _ = try self.context.logical_device.waitForFences(@ptrCast(&fence), .true, std.math.maxInt(u64));
}

pub fn present(self: *SwapChain, cmdbuf: vk.CommandBuffer) !PresentState {
    assert(self.has_acquired_image);
    const current = self.current_swap_image();

    // Reset only when we have acquired an image and are about to submit.
    const wait_stage = [_]vk.PipelineStageFlags{.{ .color_attachment_output_bit = true }};
    const frame_fence = self.frame_fences[self.frame_index];
    try self.context.logical_device.resetFences(@ptrCast(&frame_fence));
    try self.context.logical_device.queueSubmit(self.context.graphics_queue.handle, &[_]vk.SubmitInfo{.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&current.image_acquired),
        .p_wait_dst_stage_mask = &wait_stage,
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf),
        .signal_semaphore_count = 1,
        .p_signal_semaphores = @ptrCast(&current.render_finished),
    }}, frame_fence);
    self.has_acquired_image = false;
    self.frame_index = (self.frame_index + 1) % frames_in_flight;

    const result = try self.context.logical_device.queuePresentKHR(self.context.present_queue.handle, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&current.render_finished),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.chain),
        .p_image_indices = @ptrCast(&self.image_index),
    });

    return acquired_state(result).?;
}

const SwapImage = struct {
    image: vk.Image,
    view: vk.ImageView,
    image_acquired: vk.Semaphore,
    render_finished: vk.Semaphore,

    fn init(context: *const Context, image: vk.Image, format: vk.Format) !SwapImage {
        const view = try context.logical_device.createImageView(&.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        }, null);
        errdefer context.logical_device.destroyImageView(view, null);

        const image_acquired = try context.logical_device.createSemaphore(&.{}, null);
        errdefer context.logical_device.destroySemaphore(image_acquired, null);

        const render_finished = try context.logical_device.createSemaphore(&.{}, null);
        errdefer context.logical_device.destroySemaphore(render_finished, null);

        return SwapImage{
            .image = image,
            .view = view,
            .image_acquired = image_acquired,
            .render_finished = render_finished,
        };
    }

    fn deinit(self: SwapImage, context: *const Context) void {
        context.logical_device.destroyImageView(self.view, null);
        context.logical_device.destroySemaphore(self.image_acquired, null);
        context.logical_device.destroySemaphore(self.render_finished, null);
    }
};

fn create_frame_fences(self: *SwapChain) !void {
    var initialized: usize = 0;
    errdefer for (self.frame_fences[0..initialized]) |fence| {
        self.context.logical_device.destroyFence(fence, null);
    };

    for (&self.frame_fences) |*fence| {
        fence.* = try self.context.logical_device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null);
        initialized += 1;
    }
}

fn destroy_frame_fences(self: *SwapChain) void {
    for (self.frame_fences) |fence| {
        if (fence != .null_handle) self.context.logical_device.destroyFence(fence, null);
    }
    self.frame_fences = @splat(.null_handle);
}

test "swap extent honors fixed dimensions and defers zero-sized surfaces" {
    var caps: vk.SurfaceCapabilitiesKHR = undefined;
    caps.current_extent = .{ .width = 1920, .height = 1080 };
    caps.min_image_extent = .{ .width = 64, .height = 64 };
    caps.max_image_extent = .{ .width = 4096, .height = 4096 };
    try std.testing.expectEqual(caps.current_extent, try choose_swap_extent(caps, .{ .width = 800, .height = 600 }));
    caps.current_extent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) };
    try std.testing.expectEqual(vk.Extent2D{ .width = 64, .height = 4096 }, try choose_swap_extent(caps, .{ .width = 32, .height = 8192 }));
    try std.testing.expectError(error.ZeroExtent, choose_swap_extent(caps, .{ .width = 0, .height = 600 }));
    caps.min_image_extent = .{ .width = 0, .height = 0 };
    caps.max_image_extent = .{ .width = 0, .height = 0 };
    try std.testing.expectError(error.ZeroExtent, choose_swap_extent(caps, .{ .width = 800, .height = 600 }));
    caps.current_extent = .{ .width = 0, .height = 0 };
    try std.testing.expectError(error.ZeroExtent, choose_swap_extent(caps, .{ .width = 800, .height = 600 }));
}

test "acquisition skips unavailable images and suboptimal survives successful presentation" {
    try std.testing.expectEqual(null, acquired_state(.timeout));
    try std.testing.expectEqual(null, acquired_state(.not_ready));
    try std.testing.expectEqual(PresentState.optimal, acquired_state(.success).?);
    try std.testing.expectEqual(PresentState.suboptimal, acquired_state(.suboptimal_khr).?.merge(.optimal));
    try std.testing.expectEqual(PresentState.suboptimal, PresentState.optimal.merge(.suboptimal));
    try std.testing.expectEqual(PresentState.optimal, PresentState.optimal.merge(.optimal));
}
