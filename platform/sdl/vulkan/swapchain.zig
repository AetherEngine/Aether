const std = @import("std");
const vk = @import("vulkan");
const Context = @import("context.zig");

const SwapChain = @This();

pub const frames_in_flight: usize = 3;

pub const PresentState = enum {
    optimal,
    suboptimal,
};

context: *Context,
vsync: bool,
surface_capabilities: vk.SurfaceCapabilitiesKHR,
chain: vk.SwapchainKHR,
surface_format: vk.SurfaceFormatKHR,
swap_images: []SwapImage,
next_image_acquired: vk.Semaphore,
image_index: u32,
frame_fences: [frames_in_flight]vk.Fence,
frame_index: usize,

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
fn choose_swap_extent(self: *SwapChain) !vk.Extent2D {
    const surface_capabilities = self.surface_capabilities;

    // Choose the swap extent
    const width = std.math.clamp(gfx.surface.get_width(), surface_capabilities.min_image_extent.width, surface_capabilities.max_image_extent.width);
    const height = std.math.clamp(gfx.surface.get_height(), surface_capabilities.min_image_extent.height, surface_capabilities.max_image_extent.height);

    return vk.Extent2D{
        .width = width,
        .height = height,
    };
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

fn create_swapchain(self: *SwapChain, old_handle: vk.SwapchainKHR) !void {
    self.surface_capabilities = try self.context.instance.getPhysicalDeviceSurfaceCapabilitiesKHR(
        self.context.physical_device,
        self.context.surface,
    );

    const surface_format = try self.choose_swap_surface_format();
    const surface_extent = try self.choose_swap_extent();
    const present_mode = try self.choose_present_mode();

    // We want triple buffering so...
    var image_count = @max(3, self.surface_capabilities.min_image_count);
    image_count = if (self.surface_capabilities.max_image_count > 0 and image_count > self.surface_capabilities.max_image_count) self.surface_capabilities.max_image_count else image_count;

    const qfi = [_]u32{ self.context.graphics_queue.family, self.context.present_queue.family };
    const sharing_mode: vk.SharingMode = if (self.context.graphics_queue.family != self.context.present_queue.family)
        .concurrent
    else
        .exclusive;

    self.chain = self.context.logical_device.createSwapchainKHR(&.{
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
    }, null) catch return error.SwapchainCreationFailed;

    self.surface_format = surface_format;

    errdefer {
        self.context.logical_device.destroySwapchainKHR(self.chain, null);
        self.chain = .null_handle;
    }

    // Destroy the old swapchain if it exists
    if (old_handle != .null_handle) {
        self.context.logical_device.destroySwapchainKHR(old_handle, null);
    }

    self.swap_images = try self.create_swapchain_images(surface_format.format);
}

fn acquire_initial_image(self: *SwapChain) !void {
    var next_image_acquired = try self.context.logical_device.createSemaphore(&.{}, null);
    errdefer self.context.logical_device.destroySemaphore(next_image_acquired, null);

    const timeout_ns: u64 = 100_000_000; // 100ms
    const result = try self.context.logical_device.acquireNextImageKHR(self.chain, timeout_ns, next_image_acquired, .null_handle);

    if (result.result == .not_ready or result.result == .timeout) {
        return error.ImageAcquireFailed;
    }

    std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &next_image_acquired);
    self.next_image_acquired = next_image_acquired;
    self.image_index = result.image_index;
}

fn destroy_swapchain_images(self: *SwapChain) void {
    for (self.swap_images) |si| si.deinit(self.context);
    self.context.allocator.free(self.swap_images);
}

fn create_swapchain_images(self: *SwapChain, format: vk.Format) ![]SwapImage {
    const images = try self.context.logical_device.getSwapchainImagesAllocKHR(self.chain, self.context.allocator);
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
    var self: SwapChain = undefined;
    self.context = context;
    self.vsync = vsync;
    self.frame_fences = @splat(.null_handle);
    self.frame_index = 0;

    try self.create_swapchain(.null_handle);
    errdefer self.destroy_swapchain_images();
    try self.create_frame_fences();
    errdefer self.destroy_frame_fences();
    try self.acquire_initial_image();

    return self;
}

pub fn recreate(self: *SwapChain) !void {
    self.context.logical_device.deviceWaitIdle() catch {};

    if (self.chain != .null_handle) {
        self.destroy_swapchain_images();
        self.context.logical_device.destroySemaphore(self.next_image_acquired, null);
    }

    const old_handle = self.chain;
    self.chain = .null_handle;

    // create_swapchain has an internal errdefer that cleans up self.chain on failure,
    // so self.chain == .null_handle on error -- safe to retry next frame.
    try self.create_swapchain(old_handle);

    self.acquire_initial_image() catch |err| {
        self.destroy_swapchain_images();
        self.context.logical_device.destroySwapchainKHR(self.chain, null);
        self.chain = .null_handle;
        return err;
    };
}

pub fn deinit(self: *SwapChain) void {
    defer self.* = undefined;

    self.destroy_frame_fences();
    if (self.chain != .null_handle) {
        self.destroy_swapchain_images();
        self.context.logical_device.destroySemaphore(self.next_image_acquired, null);
        self.context.logical_device.destroySwapchainKHR(self.chain, null);
    }
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
    // // Step 1: Make sure the current frame has finished rendering
    const current = self.current_swap_image();

    // Step 2: Submit the command buffer
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
    self.frame_index = (self.frame_index + 1) % frames_in_flight;

    // Step 3: Present the current frame
    _ = try self.context.logical_device.queuePresentKHR(self.context.present_queue.handle, &.{
        .wait_semaphore_count = 1,
        .p_wait_semaphores = @ptrCast(&current.render_finished),
        .swapchain_count = 1,
        .p_swapchains = @ptrCast(&self.chain),
        .p_image_indices = @ptrCast(&self.image_index),
    });

    // Step 4: Acquire next frame
    const result = try self.context.logical_device.acquireNextImageKHR(
        self.chain,
        std.math.maxInt(u64),
        self.next_image_acquired,
        .null_handle,
    );

    std.mem.swap(vk.Semaphore, &self.swap_images[result.image_index].image_acquired, &self.next_image_acquired);
    self.image_index = result.image_index;

    return switch (result.result) {
        .success => .optimal,
        .suboptimal_khr => .suboptimal,
        else => unreachable,
    };
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
