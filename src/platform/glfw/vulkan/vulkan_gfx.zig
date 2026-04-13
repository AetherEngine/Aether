const std = @import("std");
const Util = @import("../../../util/util.zig");
const glfw = @import("glfw");
const Mat4 = @import("../../../math/math.zig").Mat4;

const vk = @import("vulkan");
const gfx = @import("../../gfx.zig");
const Rendering = @import("../../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;

const Context = @import("context.zig");
const Swapchain = @import("swapchain.zig");
const GarbageCollector = @import("garbage_collector.zig");
const GLFWSurface = @import("../surface.zig");

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

const PipelineData = struct {
    layout: vk.PipelineLayout,
    vert_layout: Pipeline.VertexLayout,
    pipeline: vk.Pipeline,
};

const MAX_FRAMES = 3;

const MeshData = struct {
    buffers: [MAX_FRAMES]vk.Buffer = .{.null_handle} ** MAX_FRAMES,
    memories: [MAX_FRAMES]vk.DeviceMemory = .{.null_handle} ** MAX_FRAMES,
    mapped: [MAX_FRAMES]?[*]u8 = .{null} ** MAX_FRAMES,
    capacity: usize = 0,
    pipeline: Pipeline.Handle = 0,
    built: bool = false,
};

pub const ShaderState = struct {
    view: Mat4,
    proj: Mat4,
};

/// Per-swap-image ring of camera-state slots. Each draw within a frame can
/// reference a different slot via a dynamic UBO offset, so changing the
/// projection or view matrix mid-frame actually takes effect for subsequent
/// draws (rather than the LAST write winning for the whole frame).
pub const CameraRing = struct {
    memory: vk.DeviceMemory,
    buffer: vk.Buffer,
    mapped_base: [*]u8,
    slot_stride: u32,
};

const CAMERA_SLOTS: u32 = 16;

pub const DrawState = struct {
    mat: Mat4,
    tex_id: u32,
    fog_enabled: u32 = 0,
    fog_start: f32 = 0.0,
    fog_end: f32 = 0.0,
    fog_color: [3]f32 = .{ 0.0, 0.0, 0.0 },
    alpha_blend_enabled: u32 = 1,
};

pub var draw_state = DrawState{
    .mat = Mat4.identity(),
    .tex_id = 0,
};

pub var camera_rings: []CameraRing = undefined;

var pending_state: ShaderState = .{
    .view = Mat4.identity(),
    .proj = Mat4.identity(),
};
var camera_dirty: bool = true;
var current_camera_slot: u32 = 0;
var next_camera_slot: u32 = 0;

pub var context: Context = undefined;
pub var swapchain: Swapchain = undefined;
pub var gc: GarbageCollector = undefined;

pub var command_pool: vk.CommandPool = .null_handle;
var command_buffers: []vk.CommandBuffer = undefined;
pub var command_buffer: vk.CommandBufferProxy = undefined;

var descriptor_set_layout: vk.DescriptorSetLayout = .null_handle;
var descriptor_pool: vk.DescriptorPool = .null_handle;
var descriptor_sets: []vk.DescriptorSet = undefined;

const TEXTURE_CAP: u32 = 4096;

var tex_set_layout: vk.DescriptorSetLayout = .null_handle;
var tex_pool: vk.DescriptorPool = .null_handle;
var tex_set: vk.DescriptorSet = .null_handle;
var tex_sampler: vk.Sampler = .null_handle;

const TextureRec = struct { image: vk.Image, memory: vk.DeviceMemory, view: vk.ImageView, width: u32, height: u32 };
var textures = Util.CircularBuffer(TextureRec, TEXTURE_CAP).init();

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var meshes = Util.CircularBuffer(MeshData, 8192).init();

var swap_state: Swapchain.PresentState = .optimal;
var alpha_blend_enabled: bool = true;

const depth_format: vk.Format = .d32_sfloat;
var depth_image: vk.Image = .null_handle;
var depth_image_view: vk.ImageView = .null_handle;
var depth_image_memory: vk.DeviceMemory = .null_handle;

fn create_command_pool() !void {
    command_pool = try context.logical_device.createCommandPool(&.{
        .queue_family_index = context.graphics_queue.family,
        .flags = .{
            .reset_command_buffer_bit = true,
        },
    }, null);

    command_buffers = try context.allocator.alloc(vk.CommandBuffer, swapchain.swap_images.len);
    try context.logical_device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = @intCast(swapchain.swap_images.len),
    }, command_buffers.ptr);
}

fn destroy_command_pool() void {
    context.logical_device.freeCommandBuffers(command_pool, command_buffers);
    context.allocator.free(command_buffers);
    context.logical_device.destroyCommandPool(command_pool, null);
}

fn create_uniform_buffers() !void {
    const props = context.instance.getPhysicalDeviceProperties(context.physical_device);
    const min_align: u32 = @intCast(props.limits.min_uniform_buffer_offset_alignment);
    const slot_stride: u32 = std.mem.alignForward(u32, @sizeOf(ShaderState), min_align);

    camera_rings = try render_alloc.alloc(CameraRing, swapchain.swap_images.len);

    for (camera_rings) |*ring| {
        ring.slot_stride = slot_stride;

        ring.buffer = context.logical_device.createBuffer(&.{
            .size = slot_stride * CAMERA_SLOTS,
            .usage = .{ .uniform_buffer_bit = true },
            .sharing_mode = .exclusive,
        }, null) catch unreachable;

        const mem_reqs = context.logical_device.getBufferMemoryRequirements(ring.buffer);
        ring.memory = context.allocate_gpu_buffer(mem_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true }) catch unreachable;
        context.logical_device.bindBufferMemory(ring.buffer, ring.memory, 0) catch unreachable;

        const mapped_data = context.logical_device.mapMemory(ring.memory, 0, vk.WHOLE_SIZE, .{}) catch unreachable;
        ring.mapped_base = @ptrCast(mapped_data);

        // Seed slot 0 with identity so the very first draw of the very first
        // frame has a valid binding even before set_*_matrix is called.
        @memcpy(ring.mapped_base[0..@sizeOf(ShaderState)], std.mem.asBytes(&pending_state));
    }
}

fn destroy_uniform_buffers() void {
    for (camera_rings) |ring| {
        context.logical_device.unmapMemory(ring.memory);
        context.logical_device.destroyBuffer(ring.buffer, null);
        context.logical_device.freeMemory(ring.memory, null);
    }
    render_alloc.free(camera_rings);
}

fn create_texture_set_layout() !void {
    const bindings = [_]vk.DescriptorSetLayoutBinding{
        .{ // binding 0: exactly ONE sampler
            .binding = 0,
            .descriptor_type = .sampler,
            .descriptor_count = 1,
            .stage_flags = .{ .fragment_bit = true },
        },
        .{ // binding 1: texture array (variable)
            .binding = 1,
            .descriptor_type = .sampled_image,
            .descriptor_count = TEXTURE_CAP, // max
            .stage_flags = .{ .fragment_bit = true },
        },
    };

    const bind_flags = [_]vk.DescriptorBindingFlags{
        .{ .update_after_bind_bit = true },
        .{ .partially_bound_bit = true, .update_after_bind_bit = true, .variable_descriptor_count_bit = true },
    };

    var flags_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
        .binding_count = @intCast(bindings.len),
        .p_binding_flags = @ptrCast(&bind_flags),
    };

    tex_set_layout = try context.logical_device.createDescriptorSetLayout(&.{
        .flags = .{ .update_after_bind_pool_bit = true },
        .binding_count = @intCast(bindings.len),
        .p_bindings = @ptrCast(&bindings),
        .p_next = &flags_info,
    }, null);
}

fn destroy_texture_set_layout() void {
    context.logical_device.destroyDescriptorSetLayout(tex_set_layout, null);
}

fn create_texture_descriptor_pool_and_set(actual_count: u32) !void {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{ .type = .sampler, .descriptor_count = 1 },
        .{ .type = .sampled_image, .descriptor_count = actual_count },
    };

    tex_pool = try context.logical_device.createDescriptorPool(&.{
        .flags = .{ .update_after_bind_bit = true, .free_descriptor_set_bit = true },
        .max_sets = 1,
        .pool_size_count = @intCast(pool_sizes.len),
        .p_pool_sizes = @ptrCast(&pool_sizes),
    }, null);

    // VDC applies to the LAST variable binding in the set (binding = 1 here)
    const counts = [_]u32{actual_count};
    var vdc_info = vk.DescriptorSetVariableDescriptorCountAllocateInfo{
        .descriptor_set_count = 1,
        .p_descriptor_counts = @ptrCast(&counts),
    };

    try context.logical_device.allocateDescriptorSets(&.{
        .descriptor_pool = tex_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = @ptrCast(&tex_set_layout),
        .p_next = &vdc_info,
    }, @ptrCast(&tex_set));
}

fn destroy_texture_descriptor_pool_and_set() void {
    context.logical_device.freeDescriptorSets(tex_pool, @ptrCast(&tex_set)) catch unreachable;
    context.logical_device.destroyDescriptorPool(tex_pool, null);
    tex_set = .null_handle;
    tex_pool = .null_handle;
}

fn create_texture_sampler() !void {
    tex_sampler = try context.logical_device.createSampler(&vk.SamplerCreateInfo{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mipmap_mode = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .address_mode_w = .repeat,
        .min_lod = 0,
        .max_lod = 1000,
        .anisotropy_enable = .false,
        .max_anisotropy = 1.0,
        .compare_enable = .false,
        .compare_op = .always,
        .border_color = .int_opaque_black,
        .unnormalized_coordinates = .false,
        .mip_lod_bias = 0.0,
    }, null);
}

fn destroy_texture_sampler() void {
    context.logical_device.destroySampler(tex_sampler, null);
    tex_sampler = .null_handle;
}

fn create_descriptor_set_layout() !void {
    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptor_count = 1,
        .descriptor_type = .uniform_buffer_dynamic,
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
    };

    descriptor_set_layout = try context.logical_device.createDescriptorSetLayout(&.{
        .binding_count = 1,
        .p_bindings = @ptrCast(&ubo_layout_binding),
    }, null);
}

fn destroy_descriptor_set_layout() void {
    context.logical_device.destroyDescriptorSetLayout(descriptor_set_layout, null);
}

fn create_descriptor_pool() !void {
    const pool_size = vk.DescriptorPoolSize{
        .type = .uniform_buffer_dynamic,
        .descriptor_count = @intCast(swapchain.swap_images.len),
    };

    descriptor_pool = try context.logical_device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
        .max_sets = @intCast(swapchain.swap_images.len),
        .pool_size_count = 1,
        .p_pool_sizes = @ptrCast(&pool_size),
        .flags = .{ .free_descriptor_set_bit = true },
    }, null);
}

fn destroy_descriptor_pool() void {
    context.logical_device.destroyDescriptorPool(descriptor_pool, null);
}

fn create_descriptor_sets() !void {
    const layouts = try render_alloc.alloc(vk.DescriptorSetLayout, swapchain.swap_images.len);
    defer render_alloc.free(layouts);

    for (layouts) |*layout| {
        layout.* = descriptor_set_layout;
    }

    descriptor_sets = try render_alloc.alloc(vk.DescriptorSet, swapchain.swap_images.len);

    try context.logical_device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo{
        .descriptor_pool = descriptor_pool,
        .descriptor_set_count = @intCast(swapchain.swap_images.len),
        .p_set_layouts = @ptrCast(layouts.ptr),
    }, descriptor_sets.ptr);

    for (descriptor_sets, 0..) |set, i| {
        // For dynamic UBOs, `range` is the window addressed from any dynamic
        // offset (a single ShaderState), not the whole buffer.
        const buffer_info = vk.DescriptorBufferInfo{
            .buffer = camera_rings[i].buffer,
            .offset = 0,
            .range = @sizeOf(ShaderState),
        };

        const descriptor_write = vk.WriteDescriptorSet{
            .dst_set = set,
            .dst_binding = 0,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .uniform_buffer_dynamic,
            .p_buffer_info = @ptrCast(&buffer_info),
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };

        context.logical_device.updateDescriptorSets(@ptrCast(&descriptor_write), null);
    }
}

fn destroy_descriptor_sets() void {
    context.logical_device.freeDescriptorSets(descriptor_pool, descriptor_sets) catch unreachable;
    render_alloc.free(descriptor_sets);
}

fn create_depth_image() !void {
    const width: u32 = @intCast(gfx.surface.get_width());
    const height: u32 = @intCast(gfx.surface.get_height());

    depth_image = try context.logical_device.createImage(&.{
        .image_type = .@"2d",
        .format = depth_format,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .depth_stencil_attachment_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);
    errdefer {
        context.logical_device.destroyImage(depth_image, null);
        depth_image = .null_handle;
    }

    const mem_reqs = context.logical_device.getImageMemoryRequirements(depth_image);
    depth_image_memory = try context.allocate_gpu_buffer(mem_reqs, .{ .device_local_bit = true });
    errdefer {
        context.logical_device.freeMemory(depth_image_memory, null);
        depth_image_memory = .null_handle;
    }

    try context.logical_device.bindImageMemory(depth_image, depth_image_memory, 0);

    depth_image_view = try context.logical_device.createImageView(&.{
        .image = depth_image,
        .view_type = .@"2d",
        .format = depth_format,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null);
}

fn destroy_depth_image() void {
    if (depth_image == .null_handle) return;
    context.logical_device.destroyImageView(depth_image_view, null);
    context.logical_device.destroyImage(depth_image, null);
    context.logical_device.freeMemory(depth_image_memory, null);
    depth_image = .null_handle;
    depth_image_view = .null_handle;
    depth_image_memory = .null_handle;
}

pub fn init() anyerror!void {
    context = try Context.init(render_alloc, "AetherEngine");
    swapchain = try Swapchain.init(&context, gfx.sync);
    gc = GarbageCollector.init(render_alloc);

    try create_command_pool();
    try create_depth_image();
    try create_uniform_buffers();
    try create_descriptor_set_layout();
    try create_descriptor_pool();
    try create_descriptor_sets();

    try create_texture_set_layout();
    try create_texture_descriptor_pool_and_set(4096);
    try create_texture_sampler();

    GLFWSurface.on_resize = resize_render;
}

fn resize_render() void {
    swap_state = .suboptimal;
    if (start_frame()) {
        end_frame();
    }
}

pub fn deinit() void {
    GLFWSurface.on_resize = null;
    context.logical_device.deviceWaitIdle() catch {};

    destroy_texture_sampler();
    destroy_texture_descriptor_pool_and_set();
    destroy_texture_set_layout();
    destroy_descriptor_sets();
    destroy_descriptor_pool();
    destroy_descriptor_set_layout();
    destroy_uniform_buffers();
    destroy_depth_image();
    destroy_command_pool();
    swapchain.deinit();
    gc.deinit();
    context.deinit();
}

var clear_color: [4]f32 = @splat(0);
pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    clear_color[0] = r;
    clear_color[1] = g;
    clear_color[2] = b;
    clear_color[3] = a;
}

pub fn set_alpha_blend(enabled: bool) void {
    draw_state.alpha_blend_enabled = @intFromBool(enabled);
    if (enabled == alpha_blend_enabled) return;
    alpha_blend_enabled = enabled;
    const enable: vk.Bool32 = if (enabled) .true else .false;
    command_buffer.setColorBlendEnableEXT(0, @ptrCast(&[1]vk.Bool32{enable}));
}

pub fn set_clip_planes(_: bool) void {}

pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    draw_state.fog_enabled = @intFromBool(enabled);
    draw_state.fog_start = start;
    draw_state.fog_end = end;
    draw_state.fog_color = .{ r, g, b };
}

pub fn start_frame() bool {
    if (gfx.surface.get_width() == 0 or gfx.surface.get_height() == 0) {
        @branchHint(.unlikely);
        return false;
    }

    if (swap_state == .suboptimal) {
        @branchHint(.unlikely);
        swapchain.recreate() catch return false;
        destroy_depth_image();
        create_depth_image() catch return false;
        swap_state = .optimal;
    }

    // Acquire next command buffer
    command_buffer = vk.CommandBufferProxy.init(command_buffers[swapchain.image_index], context.logical_device.wrapper);

    // Garbage collect resources
    const current = swapchain.currentSwapImage();
    _ = context.logical_device.waitForFences(@ptrCast(&current.frame_fence), .true, std.math.maxInt(u64)) catch unreachable;
    context.logical_device.resetFences(@ptrCast(&current.frame_fence)) catch unreachable;
    context.logical_device.resetCommandBuffer(command_buffer.handle, .{}) catch unreachable;
    gc.frame_index = swapchain.image_index;
    gc.collect();

    command_buffer.beginCommandBuffer(&.{}) catch unreachable;

    // Reset the camera ring for this frame. Mark dirty so the first draw
    // re-publishes whatever the user has set into slot 0.
    next_camera_slot = 0;
    current_camera_slot = 0;
    camera_dirty = true;

    const extent = vk.Extent2D{
        .width = @intCast(gfx.surface.get_width()),
        .height = @intCast(gfx.surface.get_height()),
    };

    const viewport = vk.Viewport{
        .x = 0,
        .y = @floatFromInt(gfx.surface.get_height()),
        .width = @floatFromInt(gfx.surface.get_width()),
        .height = -@as(f32, @floatFromInt(gfx.surface.get_height())),
        .min_depth = 0,
        .max_depth = 1,
    };

    const scissor = vk.Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };

    const clear_value = vk.ClearValue{ .color = .{ .float_32 = clear_color } };

    command_buffer.setViewport(0, @ptrCast(&viewport));
    command_buffer.setScissor(0, @ptrCast(&scissor));

    const pre = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .color_attachment_output_bit = true, .top_of_pipe_bit = true },
        .src_access_mask = .{}, // no accesses to wait on
        .dst_stage_mask = .{ .color_attachment_output_bit = true },
        .dst_access_mask = .{ .color_attachment_write_bit = true },
        .old_layout = .undefined, // or .present_src_khr if you track it
        .new_layout = .color_attachment_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = swapchain.currentSwapImage().image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    const depth_pre = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .early_fragment_tests_bit = true, .late_fragment_tests_bit = true },
        .dst_access_mask = .{ .depth_stencil_attachment_write_bit = true },
        .old_layout = .undefined,
        .new_layout = .depth_attachment_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = depth_image,
        .subresource_range = .{
            .aspect_mask = .{ .depth_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    const barriers = [_]vk.ImageMemoryBarrier2{ pre, depth_pre };
    const pre_dep = vk.DependencyInfo{
        .image_memory_barrier_count = 2,
        .p_image_memory_barriers = &barriers,
    };

    command_buffer.pipelineBarrier2(&pre_dep);

    const depth_attachment = vk.RenderingAttachmentInfo{
        .image_layout = .depth_attachment_optimal,
        .image_view = depth_image_view,
        .resolve_mode = .{},
        .resolve_image_layout = .undefined,
        .load_op = .clear,
        .store_op = .dont_care,
        .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
    };

    command_buffer.beginRendering(&.{
        .layer_count = 1,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = extent,
        },
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = @ptrCast(&vk.RenderingAttachmentInfo{
            .image_layout = .color_attachment_optimal,
            .image_view = swapchain.currentSwapImage().view,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = clear_value,
        }),
        .p_depth_attachment = &depth_attachment,
    });

    return true;
}

pub fn clear_depth() void {
    const attachment = vk.ClearAttachment{
        .aspect_mask = .{ .depth_bit = true },
        .color_attachment = 0,
        .clear_value = .{ .depth_stencil = .{ .depth = 1.0, .stencil = 0 } },
    };

    const rect = vk.ClearRect{
        .rect = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = @intCast(gfx.surface.get_width()),
                .height = @intCast(gfx.surface.get_height()),
            },
        },
        .base_array_layer = 0,
        .layer_count = 1,
    };

    command_buffer.clearAttachments(@ptrCast(&attachment), @ptrCast(&rect));
}

pub fn end_frame() void {
    command_buffer.endRendering();
    const post = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .color_attachment_output_bit = true },
        .src_access_mask = .{ .color_attachment_write_bit = true },
        .dst_stage_mask = .{}, // present isn't a pipeline stage
        .dst_access_mask = .{},
        .old_layout = .color_attachment_optimal,
        .new_layout = .present_src_khr,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = swapchain.currentSwapImage().image,
        .subresource_range = .{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    };

    const post_dep = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&post),
    };
    command_buffer.pipelineBarrier2(&post_dep);

    command_buffer.endCommandBuffer() catch unreachable;

    swap_state = swapchain.present(command_buffer.handle) catch |err| switch (err) {
        error.OutOfDateKHR => .suboptimal,
        else => unreachable,
    };
}

pub fn set_proj_matrix(mat: *const Mat4) void {
    pending_state.proj = mat.*;
    camera_dirty = true;
}

pub fn set_view_matrix(mat: *const Mat4) void {
    pending_state.view = mat.*;
    camera_dirty = true;
}

/// If the camera state has changed since the last draw, write it into the
/// next slot of the per-frame ring and remember which slot to bind from.
/// Back-to-back set_proj+set_view calls before any draw collapse into a
/// single slot. Called from draw_mesh.
fn flush_camera_if_dirty() void {
    if (!camera_dirty) return;

    if (next_camera_slot >= CAMERA_SLOTS) {
        Util.engine_logger.warn("Vulkan camera ring exhausted ({d} slots/frame); reusing last slot", .{CAMERA_SLOTS});
        next_camera_slot = CAMERA_SLOTS - 1;
    }

    const ring = &camera_rings[swapchain.image_index];
    const dst = ring.mapped_base + next_camera_slot * ring.slot_stride;
    @memcpy(dst[0..@sizeOf(ShaderState)], std.mem.asBytes(&pending_state));

    current_camera_slot = next_camera_slot;
    next_camera_slot += 1;
    camera_dirty = false;
}

pub fn create_pipeline(layout: Pipeline.VertexLayout, vs: ?[:0]align(4) const u8, fs: ?[:0]align(4) const u8) anyerror!Pipeline.Handle {
    if (vs == null or fs == null) return error.InvalidShader;

    const set_layouts = [_]vk.DescriptorSetLayout{ descriptor_set_layout, tex_set_layout };

    const range = vk.PushConstantRange{
        .stage_flags = .{ .vertex_bit = true, .fragment_bit = true },
        .offset = 0,
        .size = @sizeOf(DrawState),
    };

    const pl = try context.logical_device.createPipelineLayout(&.{
        .set_layout_count = @intCast(set_layouts.len),
        .p_set_layouts = &set_layouts,
        .push_constant_range_count = 1,
        .p_push_constant_ranges = @ptrCast(&range),
    }, null);

    const vert = try context.logical_device.createShaderModule(&.{
        .code_size = vs.?.len,
        .p_code = @ptrCast(@alignCast(vs.?.ptr)),
    }, null);

    const frag = try context.logical_device.createShaderModule(&.{
        .code_size = fs.?.len,
        .p_code = @ptrCast(@alignCast(fs.?.ptr)),
    }, null);

    const pipeline_shade_stage_create_info = [_]vk.PipelineShaderStageCreateInfo{
        .{
            .stage = .{ .vertex_bit = true },
            .module = vert,
            .p_name = "main",
        },
        .{
            .stage = .{ .fragment_bit = true },
            .module = frag,
            .p_name = "main",
        },
    };

    const pipeline_viewport_state_create_info = vk.PipelineViewportStateCreateInfo{
        .viewport_count = 1,
        .p_viewports = null,
        .scissor_count = 1,
        .p_scissors = null,
    };

    const pipeline_input_assembly_state_create_info = vk.PipelineInputAssemblyStateCreateInfo{
        .topology = .triangle_list,
        .primitive_restart_enable = .false,
    };

    const vertex_attribute_descriptions = try render_alloc.alloc(vk.VertexInputAttributeDescription, layout.attributes.len);
    defer render_alloc.free(vertex_attribute_descriptions);
    for (vertex_attribute_descriptions, 0..) |*desc, i| {
        const attr = layout.attributes[i];

        desc.* = .{
            .binding = attr.binding,
            .location = attr.location,
            .offset = @intCast(attr.offset),
            .format = switch (attr.format) {
                .f32x2 => .r32g32_sfloat,
                .f32x3 => .r32g32b32_sfloat,
                .unorm8x2 => .r8g8_unorm,
                .unorm8x4 => .r8g8b8a8_unorm,
                .unorm16x2 => .r16g16_unorm,
                .unorm16x3 => .r16g16b16_unorm,
                .snorm16x2 => .r16g16_snorm,
                .snorm16x3 => .r16g16b16_snorm,
            },
        };
    }

    const binding = vk.VertexInputBindingDescription{
        .binding = 0,
        .stride = @intCast(layout.stride),
        .input_rate = .vertex,
    };

    const pipeline_vertex_input_state_create_info = vk.PipelineVertexInputStateCreateInfo{
        .vertex_binding_description_count = 1,
        .p_vertex_binding_descriptions = @ptrCast(&binding),
        .vertex_attribute_description_count = @intCast(layout.attributes.len),
        .p_vertex_attribute_descriptions = @ptrCast(vertex_attribute_descriptions.ptr),
    };

    const pipeline_rasterization_state_create_info = vk.PipelineRasterizationStateCreateInfo{
        .depth_clamp_enable = .false,
        .rasterizer_discard_enable = .false,
        .polygon_mode = .fill,
        .cull_mode = .{ .back_bit = true },
        .front_face = .counter_clockwise,
        .depth_bias_enable = .false,
        .depth_bias_clamp = 0,
        .depth_bias_slope_factor = 0,
        .depth_bias_constant_factor = 0,
        .line_width = if (context.wide_lines_supported) 5.0 else 1.0,
    };

    const pipeline_multisample_state_create_info = vk.PipelineMultisampleStateCreateInfo{
        .rasterization_samples = .{ .@"1_bit" = true },
        .sample_shading_enable = .false,
        .min_sample_shading = 1,
        .alpha_to_coverage_enable = .false,
        .alpha_to_one_enable = .false,
    };

    const pipeline_color_blend_attachment_state = vk.PipelineColorBlendAttachmentState{
        .blend_enable = .true,
        .src_color_blend_factor = .src_alpha,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
        .color_write_mask = .{
            .r_bit = true,
            .g_bit = true,
            .b_bit = true,
            .a_bit = true,
        },
    };

    const pipeline_color_blend_state_create_info = vk.PipelineColorBlendStateCreateInfo{
        .logic_op_enable = .false,
        .logic_op = .copy,
        .attachment_count = 1,
        .p_attachments = @ptrCast(&pipeline_color_blend_attachment_state),
        .blend_constants = @splat(0),
    };

    const dynstate = [_]vk.DynamicState{
        .viewport,
        .scissor,
        .color_blend_enable_ext,
        .primitive_topology,
    };

    const pipeline_dynamic_state_create_info = vk.PipelineDynamicStateCreateInfo{
        .dynamic_state_count = @intCast(dynstate.len),
        .p_dynamic_states = @ptrCast(&dynstate),
    };

    const pipeline_rendering_create_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = @ptrCast(&swapchain.surface_format.format),
        .depth_attachment_format = depth_format,
        .stencil_attachment_format = .undefined,
    };

    const graphics_pipeline_create_info = vk.GraphicsPipelineCreateInfo{
        .stage_count = 2,
        .p_stages = &pipeline_shade_stage_create_info,
        .p_vertex_input_state = &pipeline_vertex_input_state_create_info,
        .p_input_assembly_state = &pipeline_input_assembly_state_create_info,
        .p_viewport_state = &pipeline_viewport_state_create_info,
        .p_rasterization_state = &pipeline_rasterization_state_create_info,
        .p_multisample_state = &pipeline_multisample_state_create_info,
        .p_color_blend_state = &pipeline_color_blend_state_create_info,
        .p_dynamic_state = &pipeline_dynamic_state_create_info,
        .layout = pl,
        .base_pipeline_handle = .null_handle,
        .base_pipeline_index = -1,
        .p_depth_stencil_state = &vk.PipelineDepthStencilStateCreateInfo{
            .depth_test_enable = .true,
            .depth_write_enable = .true,
            .depth_compare_op = .less,
            .depth_bounds_test_enable = .false,
            .stencil_test_enable = .false,
            .front = .{
                .fail_op = .keep,
                .pass_op = .keep,
                .depth_fail_op = .keep,
                .compare_op = .always,
                .compare_mask = 0,
                .write_mask = 0,
                .reference = 0,
            },
            .back = .{
                .fail_op = .keep,
                .pass_op = .keep,
                .depth_fail_op = .keep,
                .compare_op = .always,
                .compare_mask = 0,
                .write_mask = 0,
                .reference = 0,
            },
            .min_depth_bounds = 0.0,
            .max_depth_bounds = 1.0,
        },
        .p_tessellation_state = null,
        .render_pass = .null_handle,
        .subpass = 0,
        .p_next = &pipeline_rendering_create_info,
    };

    var pipeline: vk.Pipeline = .null_handle;
    if (try context.logical_device.createGraphicsPipelines(.null_handle, @ptrCast(&graphics_pipeline_create_info), null, @ptrCast(&pipeline)) != .success) {
        return error.PipelineCreationFailed;
    }

    const p_handle = pipelines.add_element(.{
        .layout = pl,
        .vert_layout = layout,
        .pipeline = pipeline,
    }) orelse return error.OutOfPipelines;

    return @intCast(p_handle);
}

pub fn destroy_pipeline(handle: Pipeline.Handle) void {
    context.logical_device.deviceWaitIdle() catch {};
    const pd = pipelines.get_element(handle) orelse return;

    context.logical_device.destroyPipeline(pd.pipeline, null);
    context.logical_device.destroyPipelineLayout(pd.layout, null);
}

pub fn bind_pipeline(handle: Pipeline.Handle) void {
    const pd = pipelines.get_element(handle) orelse return;

    command_buffer.bindPipeline(.graphics, pd.pipeline);
    // Descriptor sets are (re)bound per draw in draw_mesh because the
    // dynamic UBO offset can change as the user swaps projection/view
    // matrices mid-frame.
}

pub fn create_mesh(pipeline: Pipeline.Handle) anyerror!Mesh.Handle {
    const m_handle = meshes.add_element(.{
        .pipeline = pipeline,
    }) orelse return error.OutOfMeshes;
    return @intCast(m_handle);
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    const m_data = meshes.get_element(handle) orelse return;

    if (m_data.built) {
        for (0..MAX_FRAMES) |i| {
            if (m_data.buffers[i] != .null_handle) {
                gc.defer_destroy_buffer(m_data.buffers[i], m_data.memories[i]) catch unreachable;
            }
        }
    }

    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    var m_data = meshes.get_element(handle) orelse return;

    // Grow buffers if the current allocation is too small.
    if (data.len > m_data.capacity) {
        // Defer-destroy old buffers.
        for (0..MAX_FRAMES) |i| {
            if (m_data.buffers[i] != .null_handle) {
                gc.defer_destroy_buffer(m_data.buffers[i], m_data.memories[i]) catch unreachable;
            }
        }

        // Round up to next power of two (minimum 256 bytes).
        var new_cap: usize = 256;
        while (new_cap < data.len) new_cap *= 2;

        for (0..MAX_FRAMES) |i| {
            m_data.buffers[i] = context.logical_device.createBuffer(&.{
                .size = new_cap,
                .usage = .{ .vertex_buffer_bit = true },
                .sharing_mode = .exclusive,
            }, null) catch unreachable;

            const mem_reqs = context.logical_device.getBufferMemoryRequirements(m_data.buffers[i]);

            // Prefer device-local + host-visible (resizable BAR), fall back to host-visible only.
            m_data.memories[i] = context.allocate_gpu_buffer(mem_reqs, .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
                .device_local_bit = true,
            }) catch context.allocate_gpu_buffer(mem_reqs, .{
                .host_visible_bit = true,
                .host_coherent_bit = true,
            }) catch unreachable;

            context.logical_device.bindBufferMemory(m_data.buffers[i], m_data.memories[i], 0) catch unreachable;

            const mapped_data = context.logical_device.mapMemory(m_data.memories[i], 0, vk.WHOLE_SIZE, .{}) catch unreachable;
            m_data.mapped[i] = @ptrCast(@alignCast(mapped_data));
        }

        m_data.capacity = new_cap;
    }

    // Copy vertex data into all frame slots so every frame has current data.
    for (0..MAX_FRAMES) |i| {
        @memcpy(m_data.mapped[i].?[0..data.len], data);
    }

    m_data.built = true;
    meshes.update_element(handle, m_data);
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize, primitive: Mesh.Primitive) void {
    draw_state.mat = model.*;

    const m_data = meshes.get_element(handle) orelse return;
    const p_data = pipelines.get_element(m_data.pipeline) orelse return;

    flush_camera_if_dirty();

    const sets = [_]vk.DescriptorSet{
        descriptor_sets[swapchain.image_index],
        tex_set,
    };
    const dyn_offsets = [_]u32{current_camera_slot * camera_rings[swapchain.image_index].slot_stride};
    command_buffer.bindDescriptorSets(.graphics, p_data.layout, 0, &sets, &dyn_offsets);

    command_buffer.setPrimitiveTopology(switch (primitive) {
        .triangles => .triangle_list,
        .lines => .line_list,
    });

    const offset = [_]vk.DeviceSize{0};
    const frame_buf = m_data.buffers[swapchain.image_index];
    command_buffer.bindVertexBuffers(0, @ptrCast(&frame_buf), &offset);
    command_buffer.pushConstants(p_data.layout, .{ .vertex_bit = true, .fragment_bit = true }, 0, @sizeOf(DrawState), &draw_state);
    command_buffer.draw(@intCast(count), 1, 0, 0);
}

pub fn create_texture(width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle {
    if (width == 0 or height == 0) return error.InvalidTextureSize;
    // Expect RGBA8 pixels
    if (data.len < @as(usize, width) * @as(usize, height) * 4) return error.TextureDataTooSmall;

    const fmt: vk.Format = .r8g8b8a8_unorm;

    const image = try context.logical_device.createImage(&.{
        .image_type = .@"2d",
        .format = fmt,
        .extent = .{ .width = width, .height = height, .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null);

    const mem_reqs = context.logical_device.getImageMemoryRequirements(image);
    const memory = try context.allocate_gpu_buffer(mem_reqs, .{ .device_local_bit = true });
    try context.logical_device.bindImageMemory(image, memory, 0);

    // --- Create a staging buffer and upload the pixels ---
    const byte_count = data.len;

    const staging = try context.logical_device.createBuffer(&.{
        .size = byte_count,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null);

    const staging_reqs = context.logical_device.getBufferMemoryRequirements(staging);
    const staging_mem = try context.allocate_gpu_buffer(staging_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true });
    try context.logical_device.bindBufferMemory(staging, staging_mem, 0);

    {
        const mapped = try context.logical_device.mapMemory(staging_mem, 0, vk.WHOLE_SIZE, .{});
        defer context.logical_device.unmapMemory(staging_mem);
        const dst: [*]u8 = @ptrCast(@alignCast(mapped));
        @memcpy(dst, data);
    }

    // --- One-time command buffer: transition + copy + transition ---
    var cmdbuf_handle: vk.CommandBuffer = undefined;
    try context.logical_device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle));

    const cmdbuf = vk.CommandBufferProxy.init(cmdbuf_handle, context.logical_device.wrapper);
    try cmdbuf.beginCommandBuffer(&.{ .flags = .{ .one_time_submit_bit = true } });

    const subrange = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };

    // undefined -> transfer dst
    const pre_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .top_of_pipe_bit = true },
        .src_access_mask = .{},
        .dst_stage_mask = .{ .copy_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true },
        .old_layout = .undefined,
        .new_layout = .transfer_dst_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = subrange,
    };
    const pre_dep = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&pre_barrier),
    };
    cmdbuf.pipelineBarrier2(&pre_dep);

    // copy buffer -> image
    const copy = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0, // tightly packed
        .buffer_image_height = 0, // tightly packed
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = width, .height = height, .depth = 1 },
    };
    cmdbuf.copyBufferToImage(staging, image, .transfer_dst_optimal, @ptrCast(&copy));

    // transfer dst -> shader read
    const post_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .copy_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = subrange,
    };
    const post_dep = vk.DependencyInfo{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&post_barrier),
    };
    cmdbuf.pipelineBarrier2(&post_dep);

    try cmdbuf.endCommandBuffer();

    const submit = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf_handle),
    };
    try context.logical_device.queueSubmit(context.graphics_queue.handle, @ptrCast(&submit), .null_handle);
    try context.logical_device.queueWaitIdle(context.graphics_queue.handle);

    context.logical_device.freeCommandBuffers(command_pool, @ptrCast(&cmdbuf_handle));

    context.logical_device.destroyBuffer(staging, null);
    context.logical_device.freeMemory(staging_mem, null);

    const view = try context.logical_device.createImageView(&.{
        .image = image,
        .view_type = .@"2d",
        .format = fmt,
        .subresource_range = subrange,
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
    }, null);

    const rec = TextureRec{ .image = image, .memory = memory, .view = view, .width = width, .height = height };
    const handle_opt = textures.add_element(rec);
    if (handle_opt == null) {
        context.logical_device.destroyImageView(view, null);
        context.logical_device.destroyImage(image, null);
        context.logical_device.freeMemory(memory, null);
        return error.OutOfTextures;
    }
    const idx: u32 = @intCast(handle_opt.?);

    // Write sampler once at binding 0, elem 0
    const samp_info = vk.DescriptorImageInfo{
        .sampler = tex_sampler,
        .image_view = .null_handle,
        .image_layout = .undefined,
    };
    const write_sampler = vk.WriteDescriptorSet{
        .dst_set = tex_set,
        .dst_binding = 0,
        .dst_array_element = 0,
        .descriptor_count = 1,
        .descriptor_type = .sampler,
        .p_image_info = @ptrCast(&samp_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };

    // For each texture 'idx' at binding 1
    const img_info = vk.DescriptorImageInfo{
        .sampler = .null_handle,
        .image_view = view,
        .image_layout = .shader_read_only_optimal,
    };
    const write_image = vk.WriteDescriptorSet{
        .dst_set = tex_set,
        .dst_binding = 1,
        .dst_array_element = idx,
        .descriptor_count = 1,
        .descriptor_type = .sampled_image,
        .p_image_info = @ptrCast(&img_info),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };

    const writes = [_]vk.WriteDescriptorSet{ write_sampler, write_image };
    context.logical_device.updateDescriptorSets(&writes, null);

    return idx;
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const rec = textures.get_element(handle) orelse return;

    const byte_count = data.len;

    const staging = context.logical_device.createBuffer(&.{
        .size = byte_count,
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch return;

    const staging_reqs = context.logical_device.getBufferMemoryRequirements(staging);
    const staging_mem = context.allocate_gpu_buffer(staging_reqs, .{ .host_visible_bit = true, .host_coherent_bit = true }) catch return;
    context.logical_device.bindBufferMemory(staging, staging_mem, 0) catch return;

    {
        const mapped = context.logical_device.mapMemory(staging_mem, 0, vk.WHOLE_SIZE, .{}) catch return;
        defer context.logical_device.unmapMemory(staging_mem);
        const dst: [*]u8 = @ptrCast(@alignCast(mapped));
        @memcpy(dst, data);
    }

    var cmdbuf_handle: vk.CommandBuffer = undefined;
    context.logical_device.allocateCommandBuffers(&.{
        .command_pool = command_pool,
        .level = .primary,
        .command_buffer_count = 1,
    }, @ptrCast(&cmdbuf_handle)) catch return;

    const cmdbuf = vk.CommandBufferProxy.init(cmdbuf_handle, context.logical_device.wrapper);
    cmdbuf.beginCommandBuffer(&.{ .flags = .{ .one_time_submit_bit = true } }) catch return;

    const subrange = vk.ImageSubresourceRange{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };

    // shader read -> transfer dst
    const pre_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .fragment_shader_bit = true },
        .src_access_mask = .{ .shader_read_bit = true },
        .dst_stage_mask = .{ .copy_bit = true },
        .dst_access_mask = .{ .transfer_write_bit = true },
        .old_layout = .shader_read_only_optimal,
        .new_layout = .transfer_dst_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = rec.image,
        .subresource_range = subrange,
    };
    cmdbuf.pipelineBarrier2(&.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&pre_barrier),
    });

    const w = rec.width;
    const h = rec.height;

    const copy = vk.BufferImageCopy{
        .buffer_offset = 0,
        .buffer_row_length = 0,
        .buffer_image_height = 0,
        .image_subresource = .{
            .aspect_mask = .{ .color_bit = true },
            .mip_level = 0,
            .base_array_layer = 0,
            .layer_count = 1,
        },
        .image_offset = .{ .x = 0, .y = 0, .z = 0 },
        .image_extent = .{ .width = w, .height = h, .depth = 1 },
    };
    cmdbuf.copyBufferToImage(staging, rec.image, .transfer_dst_optimal, @ptrCast(&copy));

    // transfer dst -> shader read
    const post_barrier = vk.ImageMemoryBarrier2{
        .src_stage_mask = .{ .copy_bit = true },
        .src_access_mask = .{ .transfer_write_bit = true },
        .dst_stage_mask = .{ .fragment_shader_bit = true },
        .dst_access_mask = .{ .shader_read_bit = true },
        .old_layout = .transfer_dst_optimal,
        .new_layout = .shader_read_only_optimal,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = rec.image,
        .subresource_range = subrange,
    };
    cmdbuf.pipelineBarrier2(&.{
        .image_memory_barrier_count = 1,
        .p_image_memory_barriers = @ptrCast(&post_barrier),
    });

    cmdbuf.endCommandBuffer() catch return;

    const submit = vk.SubmitInfo{
        .command_buffer_count = 1,
        .p_command_buffers = @ptrCast(&cmdbuf_handle),
    };
    context.logical_device.queueSubmit(context.graphics_queue.handle, @ptrCast(&submit), .null_handle) catch return;
    _ = context.logical_device.queueWaitIdle(context.graphics_queue.handle) catch {};

    context.logical_device.freeCommandBuffers(command_pool, @ptrCast(&cmdbuf_handle));
    context.logical_device.destroyBuffer(staging, null);
    context.logical_device.freeMemory(staging_mem, null);
}

pub fn bind_texture(handle: Texture.Handle) void {
    draw_state.tex_id = handle;
}

pub fn destroy_texture(handle: Texture.Handle) void {
    const rec = textures.get_element(handle) orelse return;

    // Null out the image slot in the bindless array (binding 1).
    // Binding 0 is a single shared sampler (element 0 only) — don't touch it here.
    const null_img = vk.DescriptorImageInfo{
        .sampler = .null_handle,
        .image_view = .null_handle,
        .image_layout = .undefined,
    };
    const clear_image = vk.WriteDescriptorSet{
        .dst_set = tex_set,
        .dst_binding = 1,
        .dst_array_element = handle,
        .descriptor_count = 1,
        .descriptor_type = .sampled_image,
        .p_image_info = @ptrCast(&null_img),
        .p_buffer_info = undefined,
        .p_texel_buffer_view = undefined,
    };
    context.logical_device.updateDescriptorSets(@ptrCast(&clear_image), null);

    _ = context.logical_device.deviceWaitIdle() catch {};

    context.logical_device.destroyImageView(rec.view, null);
    context.logical_device.destroyImage(rec.image, null);
    context.logical_device.freeMemory(rec.memory, null);

    _ = textures.remove_element(handle);
}

pub fn force_texture_resident(_: Texture.Handle) void {}
