//! Nintendo 3DS Mango backend.
//!
//! This follows the same ownership shape as the deko3D backend: the surface
//! owns the display device/swapchains, while this module owns renderer state
//! and backend resources.

const std = @import("std");
const zitrus = @import("zitrus");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const vertex = Rendering.vertex;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const gfx = @import("../gfx.zig");
const basic_vert align(@alignOf(u32)) = @embedFile("aether_basic_vert").*;

const horizon = zitrus.horizon;
const mango = zitrus.mango;
const pica = zitrus.hardware.pica;

const MAX_TEXTURES = 256;
const PAGE_SIZE = 4096;
const SCREEN_WIDTH: u32 = 800;
const SCREEN_HEIGHT: u32 = 240;
const SCREEN_TOP_WIDTH = 240;
const SCREEN_TOP_HEIGHT = 800;
const SCREEN_BOTTOM_WIDTH = 240;
const SCREEN_BOTTOM_HEIGHT = 320;
const COMMAND_BUFFER_COUNT = 2;
const FRAME_SYNC_TIMEOUT_NS = 2 * std.time.ns_per_s;
const TEX_BPP = 4;
const POS_SCALE: [4]f32 = .{ snorm16_scale(), snorm16_scale(), snorm16_scale(), 1.0 };
const UV_SCALE: [4]f32 = .{ snorm16_scale(), snorm16_scale(), 0.0, 0.0 };
const COLOR_SCALE: [4]f32 = .{ unorm8_scale(), unorm8_scale(), unorm8_scale(), unorm8_scale() };

const MeshData = struct {
    buffer: mango.Buffer = .null,
    memory: mango.DeviceMemory = .null,
    size: u32 = 0,
};

const TextureData = struct {
    memory: mango.DeviceMemory = .null,
    image: mango.Image = .null,
    view: mango.ImageView = .null,
    width: u32 = 0,
    height: u32 = 0,
    alive: bool = false,
};

const RenderTarget = struct {
    memory: mango.DeviceMemory = .null,
    image: mango.Image = .null,
    view: mango.ImageView = .null,
};

pub const ShaderState = struct {
    view: Mat4,
    proj: Mat4,
};

pub const DrawState = struct {
    mat: Mat4,
    tex_id: u32,
    fog_enabled: u32 = 0,
    fog_start: f32 = 0.0,
    fog_end: f32 = 0.0,
    fog_color: [3]f32 = .{ 0.0, 0.0, 0.0 },
    alpha_blend_enabled: u32 = 1,
    uv_offset: [2]f32 = .{ 0.0, 0.0 },
};

const MemoryHeap = enum(u2) {
    fcram,
    vram_a,
    vram_b,
};

const ExternalMemoryData = packed struct(u64) {
    valid: bool = true,
    virtual_page_shifted: u20,
    physical_page_shifted: u20,
    size_page_shifted: u20,
    heap: MemoryHeap,
    _: u1 = 0,
};

const ScreenState = struct {
    command_buffer: mango.CommandBuffer = .null,
    recording: bool = false,
    render_open: bool = false,
};

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

var meshes = Util.CircularBuffer(MeshData, 8192).init();
var texture_slots = Util.CircularBuffer(TextureData, MAX_TEXTURES).init();

pub var draw_state = DrawState{
    .mat = Mat4.identity(),
    .tex_id = 0,
};
var pending_state = ShaderState{
    .view = Mat4.identity(),
    .proj = Mat4.identity(),
};
var projection_transform: Mat4 = Mat4.identity();

var initialized = false;
var clear_color: [4]u8 = .{ 0, 0, 0, 255 };
var current_screen: gfx.Surface.Screen = .top;
var bottom_touched = false;
var bottom_presented = false;
var vsync_enabled = true;
var depth_write_enabled = true;
var culling_enabled = true;
var current_texture: Texture.Handle = 0;
var command_pool: mango.CommandPool = .null;
var command_buffers: [COMMAND_BUFFER_COUNT]mango.CommandBuffer = @splat(.null);
var top_frame_semaphore: mango.Semaphore = .null;
var bottom_frame_semaphore: mango.Semaphore = .null;
var top_next_sync_value: u64 = 0;
var bottom_next_sync_value: u64 = 0;
var top_frame_wait: u64 = 0;
var bottom_frame_wait: u64 = 0;
var top_wait: u64 = 0;
var bottom_wait: u64 = 0;
var top_state = ScreenState{};
var bottom_state = ScreenState{};
var top_target = RenderTarget{};
var bottom_target = RenderTarget{};
var basic_shader: mango.Shader = .null;
var vertex_input: mango.VertexInputLayout = .null;
var texture_sampler: mango.Sampler = .null;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

pub fn init() anyerror!void {
    _ = render_io;
    command_pool = try gfx.surface.device.createCommandPool(.{
        .initial_command_buffers = COMMAND_BUFFER_COUNT,
    }, null);
    errdefer cleanup_renderer_resources();

    try gfx.surface.device.allocateCommandBuffers(.{
        .pool = command_pool,
        .command_buffer_count = COMMAND_BUFFER_COUNT,
    }, &command_buffers);
    top_state.command_buffer = command_buffers[0];
    bottom_state.command_buffer = command_buffers[1];

    basic_shader = try gfx.surface.device.createShader(.init(.psh, &basic_vert, "main"), null);
    vertex_input = try create_vertex_input();
    texture_sampler = try gfx.surface.device.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mip_filter = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .lod_bias = 0.0,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = @splat(0),
    }, null);

    top_frame_semaphore = try gfx.surface.device.createSemaphore(.initial_zero, null);
    errdefer {
        gfx.surface.device.destroySemaphore(top_frame_semaphore, null);
        top_frame_semaphore = .null;
    }
    bottom_frame_semaphore = try gfx.surface.device.createSemaphore(.initial_zero, null);
    errdefer {
        gfx.surface.device.destroySemaphore(bottom_frame_semaphore, null);
        bottom_frame_semaphore = .null;
    }
    top_next_sync_value = 0;
    bottom_next_sync_value = 0;
    top_frame_wait = 0;
    bottom_frame_wait = 0;
    top_wait = 0;
    bottom_wait = 0;
    bottom_presented = false;

    top_target = try create_render_target(.top);
    errdefer destroy_render_target(&top_target);
    bottom_target = try create_render_target(.bottom);
    errdefer destroy_render_target(&bottom_target);

    init_projection_transform();

    initialized = true;
    set_vsync(vsync_enabled);
}

pub fn deinit() void {
    if (!initialized) return;
    gfx.surface.device.waitIdle();
    submit_state_reset();
    destroy_all_meshes();
    destroy_all_textures();
    cleanup_renderer_resources();
    initialized = false;
    bottom_presented = false;
    top_next_sync_value = 0;
    bottom_next_sync_value = 0;
    top_frame_wait = 0;
    bottom_frame_wait = 0;
    top_wait = 0;
    bottom_wait = 0;
}

pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    clear_color = .{ float_to_u8(r), float_to_u8(g), float_to_u8(b), float_to_u8(a) };
}

pub fn set_alpha_blend(enabled: bool) void {
    draw_state.alpha_blend_enabled = @intFromBool(enabled);
}

pub fn set_depth_write(enabled: bool) void {
    depth_write_enabled = enabled;
}

pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    draw_state.fog_enabled = @intFromBool(enabled);
    draw_state.fog_start = start;
    draw_state.fog_end = end;
    draw_state.fog_color = .{ r, g, b };
}

pub fn set_clip_planes(_: bool) void {}

pub fn set_culling(enabled: bool) void {
    culling_enabled = enabled;
}

pub fn set_uv_offset(u: f32, v: f32) void {
    draw_state.uv_offset = .{ u, v };
}

pub fn set_proj_matrix(m: *const Mat4) void {
    pending_state.proj = m.*;
}

pub fn set_view_matrix(m: *const Mat4) void {
    pending_state.view = m.*;
}

pub fn start_frame() bool {
    if (!initialized or gfx.surface.device == .null) return false;

    wait_for_frame_sync() catch |err| {
        std.log.err("3DS Mango frame wait failed: {s}", .{@errorName(err)});
        return false;
    };
    submit_state_reset();
    current_screen = .top;
    bottom_touched = false;
    top_wait = queue_clear_screen(.top, 0) catch |err| {
        std.log.err("3DS Mango top clear failed: {s}", .{@errorName(err)});
        return false;
    };
    return true;
}

pub fn end_frame() void {
    if (!initialized or gfx.surface.device == .null) return;

    top_wait = queue_submit_screen(.top, top_wait) catch |err| blk: {
        std.log.err("3DS Mango top submit failed: {s}", .{@errorName(err)});
        break :blk 0;
    };

    const update_bottom = bottom_touched or !bottom_presented;
    if (update_bottom and !bottom_touched) {
        bottom_wait = queue_clear_screen(.bottom, 0) catch |err| {
            std.log.err("3DS Mango bottom clear failed: {s}", .{@errorName(err)});
            return;
        };
    }

    if (update_bottom) {
        bottom_wait = queue_submit_screen(.bottom, bottom_wait) catch |err| blk: {
            std.log.err("3DS Mango bottom submit failed: {s}", .{@errorName(err)});
            break :blk 0;
        };
    }

    top_wait = blit_screen_to_swapchain(.top, top_wait) catch |err| blk: {
        std.log.err("3DS Mango top blit failed: {s}", .{@errorName(err)});
        break :blk 0;
    };
    if (update_bottom) {
        bottom_wait = blit_screen_to_swapchain(.bottom, bottom_wait) catch |err| blk: {
            std.log.err("3DS Mango bottom blit failed: {s}", .{@errorName(err)});
            break :blk 0;
        };
    }

    gfx.surface.present(.top, top_wait, top_frame_semaphore) catch |err| {
        std.log.err("3DS Mango top present failed: {s}", .{@errorName(err)});
    };
    if (update_bottom) {
        gfx.surface.present(.bottom, bottom_wait, bottom_frame_semaphore) catch |err| {
            std.log.err("3DS Mango bottom present failed: {s}", .{@errorName(err)});
        };
        bottom_presented = true;
    }
    top_frame_wait = @max(top_frame_wait, top_wait);
    if (update_bottom) bottom_frame_wait = @max(bottom_frame_wait, bottom_wait);
}

pub fn clear_depth() void {}

pub fn has_second_screen() bool {
    return true;
}

pub fn switch_second_screen() void {
    current_screen = .bottom;
    bottom_touched = true;
    bottom_wait = queue_clear_screen(.bottom, 0) catch |err| blk: {
        std.log.err("3DS Mango bottom clear failed: {s}", .{@errorName(err)});
        break :blk 0;
    };
}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
}

pub fn create_mesh() anyerror!Mesh.Handle {
    return meshes.add_element(.{}) orelse error.OutOfMeshSlots;
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    const mesh = meshes.get_element_ptr(handle) orelse return;
    destroy_mesh_data(mesh);
    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    const mesh = meshes.get_element_ptr(handle) orelse return;
    destroy_mesh_data(mesh);
    if (data.len == 0) return;

    if (!is_linear_range(data)) {
        std.log.err("3DS Mango mesh update received non-linear memory; use std.process.Init.gpa for mesh storage", .{});
        return;
    }
    if (data.len > std.math.maxInt(u32)) {
        std.log.err("3DS Mango mesh update too large: {} bytes", .{data.len});
        return;
    }

    const buffer = gfx.surface.device.createBuffer(.{
        .size = .size(@intCast(data.len)),
        .usage = .{ .vertex_buffer = true },
    }, null) catch |err| {
        std.log.err("3DS Mango buffer creation failed: {s}", .{@errorName(err)});
        return;
    };

    const memory = external_memory(data);
    gfx.surface.device.bindBufferMemory(buffer, memory, .size(@intCast(page_offset(data)))) catch |err| {
        std.log.err("3DS Mango buffer bind failed: {s}", .{@errorName(err)});
        gfx.surface.device.destroyBuffer(buffer, null);
        return;
    };

    _ = horizon.flushProcessDataCache(.current, data);
    mesh.* = .{
        .buffer = buffer,
        .memory = memory,
        .size = @intCast(data.len),
    };
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize) void {
    const mesh = meshes.get_element_ptr(handle) orelse return;
    if (mesh.buffer == .null or count == 0) return;
    if (count > std.math.maxInt(usize) / vertex.Layout.stride) return;
    if (count * vertex.Layout.stride > mesh.size) return;

    draw_state.mat = model.*;

    const cmd = begin_screen_recording(current_screen) catch |err| {
        std.log.err("3DS Mango command recording failed: {s}", .{@errorName(err)});
        return;
    };

    var uniforms = matrix_uniforms(model, &pending_state.view, &pending_state.proj);
    cmd.bindFloatUniforms(.vertex, 0, &uniforms);

    bind_draw_texture_state(cmd);

    const buffers = [_]mango.Buffer{mesh.buffer};
    const offsets = [_]u32{0};
    cmd.bindVertexBuffersSlice(0, &buffers, &offsets);
    cmd.draw(@intCast(count), 0);
}

pub fn create_texture(width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle {
    if (!valid_texture_dimensions(width, height)) return error.UnsupportedTextureSize;
    if (data.len < @as(usize, width) * @as(usize, height) * 4) return error.TextureDataTooSmall;

    const handle = texture_slots.add_element(.{}) orelse return error.OutOfTextureSlots;
    const texture = texture_slots.get_element_ptr(handle) orelse return error.OutOfTextureSlots;
    errdefer {
        destroy_texture_data(texture);
        _ = texture_slots.remove_element(handle);
    }

    texture.* = .{
        .width = width,
        .height = height,
    };
    try create_texture_resources(texture);
    try upload_texture_pixels(texture, data);
    texture.alive = true;
    return @intCast(handle);
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const texture = texture_slots.get_element_ptr(handle) orelse return;
    if (!texture.alive) return;
    if (data.len < @as(usize, texture.width) * @as(usize, texture.height) * 4) return;
    upload_texture_pixels(texture, data) catch |err| {
        std.log.err("3DS Mango texture upload failed: {s}", .{@errorName(err)});
    };
}

pub fn bind_texture(handle: Texture.Handle) void {
    if (handle != 0) {
        const texture = texture_slots.get_element(handle) orelse return;
        if (!texture.alive) return;
    }
    current_texture = handle;
    draw_state.tex_id = @intCast(handle);
}

pub fn destroy_texture(handle: Texture.Handle) void {
    const texture = texture_slots.get_element_ptr(handle) orelse return;
    destroy_texture_data(texture);
    _ = texture_slots.remove_element(handle);
    if (current_texture == handle) current_texture = 0;
}

pub fn force_texture_resident(_: Texture.Handle) void {}

fn wait_for_frame_sync() !void {
    if (top_frame_wait != 0) {
        gfx.surface.device.waitSemaphores(.init(&.{top_frame_semaphore}, &.{top_frame_wait}), FRAME_SYNC_TIMEOUT_NS) catch |err| {
            std.log.err("3DS Mango top frame semaphore wait stalled: target={} next={}", .{ top_frame_wait, top_next_sync_value });
            return err;
        };
    }
    if (bottom_frame_wait != 0) {
        gfx.surface.device.waitSemaphores(.init(&.{bottom_frame_semaphore}, &.{bottom_frame_wait}), FRAME_SYNC_TIMEOUT_NS) catch |err| {
            std.log.err("3DS Mango bottom frame semaphore wait stalled: target={} next={}", .{ bottom_frame_wait, bottom_next_sync_value });
            return err;
        };
    }
}

fn screen_semaphore(screen: gfx.Surface.Screen) mango.Semaphore {
    return switch (screen) {
        .top => top_frame_semaphore,
        .bottom => bottom_frame_semaphore,
    };
}

fn next_frame_sync_value(screen: gfx.Surface.Screen) u64 {
    switch (screen) {
        .top => {
            top_next_sync_value += 1;
            return top_next_sync_value;
        },
        .bottom => {
            bottom_next_sync_value += 1;
            return bottom_next_sync_value;
        },
    }
}

fn queue_clear_screen(screen: gfx.Surface.Screen, wait_value: u64) !u64 {
    const semaphore = screen_semaphore(screen);
    const signal_value = next_frame_sync_value(screen);
    const wait_op: ?mango.SemaphoreQueueOperation = if (wait_value == 0)
        null
    else
        .init(semaphore, wait_value);
    const signal_op = mango.SemaphoreQueueOperation.init(semaphore, signal_value);
    try gfx.surface.queues.get(.fill).clearColorImage(.{
        .wait_semaphore = if (wait_op) |*op| op else null,
        .subresource_range = .full,
        .image = render_target(screen).image,
        .color = clear_color,
        .signal_semaphore = &signal_op,
    });
    return signal_value;
}

fn create_vertex_input() !mango.VertexInputLayout {
    const bindings = [_]mango.VertexInputBindingDescription{
        .{ .stride = @intCast(vertex.Layout.stride) },
    };
    const attributes = [_]mango.VertexInputAttributeDescription{
        .{
            .location = .v0,
            .binding = .@"0",
            .format = .r16g16b16a16_sscaled,
            .offset = @offsetOf(vertex.Vertex, "pos"),
        },
        .{
            .location = .v1,
            .binding = .@"0",
            .format = .r8g8b8a8_uscaled,
            .offset = @offsetOf(vertex.Vertex, "color"),
        },
        .{
            .location = .v2,
            .binding = .@"0",
            .format = .r16g16_sscaled,
            .offset = @offsetOf(vertex.Vertex, "uv"),
        },
    };
    return gfx.surface.device.createVertexInputLayout(.init(&bindings, &attributes, &.{}), null);
}

fn begin_screen_recording(screen: gfx.Surface.Screen) !mango.CommandBuffer {
    const state = screen_state(screen);
    if (state.recording) return state.command_buffer;

    const cmd = state.command_buffer;
    try cmd.begin();
    cmd.bindShaders(&.{.vertex}, &.{basic_shader});
    set_default_graphics_state(cmd, screen);
    cmd.beginRendering(.{
        .color_attachment = render_target(screen).view,
        .depth_stencil_attachment = .null,
    });

    state.recording = true;
    state.render_open = true;
    return cmd;
}

fn queue_submit_screen(screen: gfx.Surface.Screen, wait_value: u64) !u64 {
    const state = screen_state(screen);
    if (!state.recording) return wait_value;
    const semaphore = screen_semaphore(screen);
    const signal_value = next_frame_sync_value(screen);
    const wait_op: ?mango.SemaphoreQueueOperation = if (wait_value == 0)
        null
    else
        .init(semaphore, wait_value);
    const signal_op = mango.SemaphoreQueueOperation.init(semaphore, signal_value);

    const cmd = state.command_buffer;
    if (state.render_open) {
        cmd.endRendering();
        state.render_open = false;
    }
    try cmd.end();
    try gfx.surface.queues.get(.submit).submit(.{
        .wait_semaphore = if (wait_op) |*op| op else null,
        .command_buffer = cmd,
        .signal_semaphore = &signal_op,
    });
    state.recording = false;
    return signal_value;
}

fn blit_screen_to_swapchain(screen: gfx.Surface.Screen, wait_value: u64) !u64 {
    const semaphore = screen_semaphore(screen);
    const signal_value = next_frame_sync_value(screen);
    const wait_op: ?mango.SemaphoreQueueOperation = if (wait_value == 0)
        null
    else
        .init(semaphore, wait_value);
    const signal_op = mango.SemaphoreQueueOperation.init(semaphore, signal_value);
    try gfx.surface.acquire(screen);
    try gfx.surface.queues.get(.transfer).blitImage(.{
        .wait_semaphore = if (wait_op) |*op| op else null,
        .src_image = render_target(screen).image,
        .dst_image = gfx.surface.current_image(screen),
        .src_subresource = .full,
        .dst_subresource = .full,
        .signal_semaphore = &signal_op,
    });
    return signal_value;
}

fn set_default_graphics_state(cmd: mango.CommandBuffer, screen: gfx.Surface.Screen) void {
    const dims = screen_dimensions(screen);
    const rect = mango.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = dims.width, .height = dims.height },
    };
    cmd.setDepthMode(.z_buffer);
    cmd.setCullMode(if (culling_enabled) .back else .none);
    cmd.setFrontFace(.ccw);
    cmd.setPrimitiveTopology(.triangle_list);
    cmd.setViewport(.{
        .rect = rect,
        .min_depth = 0.0,
        .max_depth = 1.0,
    });
    cmd.setScissor(.inside(rect));
    bind_primary_color_state(cmd);
    cmd.setBlendEquation(.{
        .src_color_factor = .src_alpha,
        .dst_color_factor = .one_minus_src_alpha,
        .color_op = .add,
        .src_alpha_factor = .one,
        .dst_alpha_factor = .one_minus_src_alpha,
        .alpha_op = .add,
    });
    cmd.setColorWriteMask(.rgba);
    cmd.setDepthTestEnable(false);
    cmd.setDepthCompareOp(.le);
    cmd.setDepthWriteEnable(depth_write_enabled);
    cmd.setDepthBias(0.0);
    cmd.setLogicOpEnable(false);
    cmd.setLogicOp(.copy);
    cmd.setAlphaTestEnable(false);
    cmd.setAlphaTestCompareOp(.always);
    cmd.setAlphaTestReference(0);
    cmd.setStencilTestEnable(false);
    cmd.setStencilOp(.keep, .keep, .keep, .always);
    cmd.setStencilCompareMask(0xff);
    cmd.setStencilWriteMask(0xff);
    cmd.setStencilReference(0);
    cmd.setVertexInput(vertex_input);
    cmd.setTextureCoordinates(.@"2", .@"2");
    cmd.setLightingEnable(false);
}

fn bind_draw_texture_state(cmd: mango.CommandBuffer) void {
    const texture = texture_slots.get_element(current_texture) orelse {
        bind_primary_color_state(cmd);
        return;
    };
    if (!texture.alive or texture.view == .null or texture_sampler == .null) {
        bind_primary_color_state(cmd);
        return;
    }
    cmd.bindCombinedImageSamplers(0, &.{.{
        .image = texture.view,
        .sampler = texture_sampler,
    }});
    cmd.setTextureCombiners(&texture_combiners, &texture_combiner_sources);
}

fn bind_primary_color_state(cmd: mango.CommandBuffer) void {
    cmd.bindCombinedImageSamplers(0, &.{mango.CombinedImageSampler.none});
    cmd.setTextureCombiners(&primary_color_combiners, &texture_combiner_sources);
}

const primary_color_combiners: [6]mango.TextureCombinerUnit = .{
    primary_color_combiner(),
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
};

const texture_combiners: [6]mango.TextureCombinerUnit = .{
    primary_color_combiner(),
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    texture_color_combiner(),
};

const texture_combiner_sources: [4]mango.TextureCombinerUnit.BufferSources = @splat(.previous);

fn primary_color_combiner() mango.TextureCombinerUnit {
    return .{
        .color_src = @splat(.primary_color),
        .alpha_src = @splat(.primary_color),
        .color_factor = @splat(.src_color),
        .alpha_factor = @splat(.src_alpha),
        .color_op = .replace,
        .alpha_op = .replace,
        .color_scale = .@"1x",
        .alpha_scale = .@"1x",
        .constant = @splat(0),
    };
}

fn texture_color_combiner() mango.TextureCombinerUnit {
    return .{
        .color_src = .{ .primary_color, .texture_0, .primary_color },
        .alpha_src = .{ .primary_color, .texture_0, .primary_color },
        .color_factor = @splat(.src_color),
        .alpha_factor = @splat(.src_alpha),
        .color_op = .modulate,
        .alpha_op = .modulate,
        .color_scale = .@"1x",
        .alpha_scale = .@"1x",
        .constant = @splat(0),
    };
}

fn matrix_uniforms(model: *const Mat4, view: *const Mat4, proj: *const Mat4) [11][4]f32 {
    var uniforms: [11][4]f32 = undefined;
    const projection = mat4_to_uniform_rows(Mat4.mul(proj.*, projection_transform));
    const model_view = mat4_to_uniform_rows(Mat4.mul(model.*, view.*));
    for (projection, 0..) |row, i| uniforms[i] = row;
    for (model_view, 0..) |row, i| uniforms[i + 4] = row;
    uniforms[8] = POS_SCALE;
    uniforms[9] = .{ UV_SCALE[0], UV_SCALE[1], draw_state.uv_offset[0], draw_state.uv_offset[1] };
    uniforms[10] = COLOR_SCALE;
    return uniforms;
}

fn mat4_to_uniform_rows(mat: Mat4) [4][4]f32 {
    var out: [4][4]f32 = undefined;
    inline for (0..4) |row| {
        out[row] = .{ mat.data[0][row], mat.data[1][row], mat.data[2][row], mat.data[3][row] };
    }
    return out;
}

fn init_projection_transform() void {
    projection_transform = Mat4.mul(
        logical_viewport_transform(),
        ortho_tilt(0.0, @floatFromInt(SCREEN_WIDTH), 0.0, @floatFromInt(SCREEN_HEIGHT), 0.0, 1.0),
    );
}

fn logical_viewport_transform() Mat4 {
    return .{ .data = .{
        .{ @as(f32, @floatFromInt(SCREEN_WIDTH)) * 0.5, 0.0, 0.0, 0.0 },
        .{ 0.0, @as(f32, @floatFromInt(SCREEN_HEIGHT)) * 0.5, 0.0, 0.0 },
        .{ 0.0, 0.0, -1.0, 0.0 },
        .{ @as(f32, @floatFromInt(SCREEN_WIDTH)) * 0.5, @as(f32, @floatFromInt(SCREEN_HEIGHT)) * 0.5, 1.0, 1.0 },
    } };
}

fn ortho_tilt(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32) Mat4 {
    const rl = right - left;
    const tb = top - bottom;
    const fnv = far - near;
    return .{ .data = .{
        .{ 0.0, -2.0 / rl, 0.0, 0.0 },
        .{ 2.0 / tb, 0.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0 / fnv, 0.0 },
        .{ -((top + bottom) / tb), (right + left) / rl, 0.5 * ((near + far) / (near - far)) - 0.5, 1.0 },
    } };
}

fn screen_dimensions(screen: gfx.Surface.Screen) mango.Extent2D {
    return switch (screen) {
        .top => .{ .width = SCREEN_TOP_WIDTH, .height = SCREEN_TOP_HEIGHT },
        .bottom => .{ .width = SCREEN_BOTTOM_WIDTH, .height = SCREEN_BOTTOM_HEIGHT },
    };
}

fn screen_state(screen: gfx.Surface.Screen) *ScreenState {
    return switch (screen) {
        .top => &top_state,
        .bottom => &bottom_state,
    };
}

fn render_target(screen: gfx.Surface.Screen) *RenderTarget {
    return switch (screen) {
        .top => &top_target,
        .bottom => &bottom_target,
    };
}

fn submit_state_reset() void {
    reset_screen_state(&top_state);
    reset_screen_state(&bottom_state);
}

fn reset_screen_state(state: *ScreenState) void {
    if (state.recording and state.command_buffer != .null) {
        if (state.render_open) {
            state.command_buffer.endRendering();
        }
        state.command_buffer.end() catch {};
    }
    state.recording = false;
    state.render_open = false;
}

fn cleanup_renderer_resources() void {
    if (gfx.surface.device == .null) return;

    destroy_render_target(&bottom_target);
    destroy_render_target(&top_target);

    if (vertex_input != .null) {
        gfx.surface.device.destroyVertexInputLayout(vertex_input, null);
        vertex_input = .null;
    }
    if (basic_shader != .null) {
        gfx.surface.device.destroyShader(basic_shader, null);
        basic_shader = .null;
    }
    if (texture_sampler != .null) {
        gfx.surface.device.destroySampler(texture_sampler, null);
        texture_sampler = .null;
    }
    if (bottom_frame_semaphore != .null) {
        gfx.surface.device.destroySemaphore(bottom_frame_semaphore, null);
        bottom_frame_semaphore = .null;
    }
    if (top_frame_semaphore != .null) {
        gfx.surface.device.destroySemaphore(top_frame_semaphore, null);
        top_frame_semaphore = .null;
    }
    if (command_pool != .null) {
        gfx.surface.device.freeCommandBuffers(command_pool, &command_buffers);
        gfx.surface.device.destroyCommandPool(command_pool, null);
        command_pool = .null;
    }
    command_buffers = @splat(.null);
    top_state = .{};
    bottom_state = .{};
}

fn destroy_all_meshes() void {
    for (meshes.buffer[1..]) |*maybe_mesh| {
        if (maybe_mesh.*) |*mesh| destroy_mesh_data(mesh);
        maybe_mesh.* = null;
    }
    meshes.clear();
}

fn destroy_all_textures() void {
    for (texture_slots.buffer[1..]) |*maybe_texture| {
        if (maybe_texture.*) |*texture| destroy_texture_data(texture);
        maybe_texture.* = null;
    }
    texture_slots.clear();
    current_texture = 0;
    draw_state.tex_id = 0;
}

fn destroy_mesh_data(mesh: *MeshData) void {
    if (mesh.buffer != .null and gfx.surface.device != .null) {
        gfx.surface.device.destroyBuffer(mesh.buffer, null);
    }
    mesh.* = .{};
}

fn create_render_target(screen: gfx.Surface.Screen) !RenderTarget {
    const dims = screen_dimensions(screen);
    const byte_count = @as(u32, dims.width) * @as(u32, dims.height) * 4;

    var target = RenderTarget{};
    target.memory = try gfx.surface.device.allocateMemory(.{
        .allocation_size = .size(byte_count),
        .memory_type = .vram_a,
    }, null);
    errdefer {
        gfx.surface.device.freeMemory(target.memory, null);
        target.memory = .null;
    }

    target.image = try gfx.surface.device.createImage(.{
        .flags = .{},
        .type = .@"2d",
        .tiling = .optimal,
        .usage = .{
            .transfer_src = true,
            .color_attachment = true,
        },
        .extent = dims,
        .format = .a8b8g8r8_unorm,
        .mip_levels = .@"1",
        .array_layers = .@"1",
    }, null);
    errdefer {
        gfx.surface.device.destroyImage(target.image, null);
        target.image = .null;
    }

    try gfx.surface.device.bindImageMemory(target.image, target.memory, .size(0));

    target.view = try gfx.surface.device.createImageView(.{
        .type = .@"2d",
        .format = .a8b8g8r8_unorm,
        .image = target.image,
        .subresource_range = .full,
    }, null);
    errdefer {
        gfx.surface.device.destroyImageView(target.view, null);
        target.view = .null;
    }

    return target;
}

fn destroy_render_target(target: *RenderTarget) void {
    if (gfx.surface.device != .null) {
        if (target.view != .null) {
            gfx.surface.device.destroyImageView(target.view, null);
        }
        if (target.image != .null) {
            gfx.surface.device.destroyImage(target.image, null);
        }
        if (target.memory != .null) {
            gfx.surface.device.freeMemory(target.memory, null);
        }
    }
    target.* = .{};
}

fn create_texture_resources(texture: *TextureData) !void {
    const byte_count = texture_byte_count(texture.width, texture.height);
    texture.memory = try gfx.surface.device.allocateMemory(.{
        .allocation_size = .size(byte_count),
        .memory_type = .vram_a,
    }, null);
    errdefer {
        gfx.surface.device.freeMemory(texture.memory, null);
        texture.memory = .null;
    }

    texture.image = try gfx.surface.device.createImage(.{
        .flags = .{},
        .type = .@"2d",
        .tiling = .optimal,
        .usage = .{
            .transfer_dst = true,
            .sampled = true,
        },
        .extent = .{ .width = @intCast(texture.width), .height = @intCast(texture.height) },
        .format = .a8b8g8r8_unorm,
        .mip_levels = .@"1",
        .array_layers = .@"1",
    }, null);
    errdefer {
        gfx.surface.device.destroyImage(texture.image, null);
        texture.image = .null;
    }

    try gfx.surface.device.bindImageMemory(texture.image, texture.memory, .size(0));

    texture.view = try gfx.surface.device.createImageView(.{
        .type = .@"2d",
        .format = .a8b8g8r8_unorm,
        .image = texture.image,
        .subresource_range = .full,
    }, null);
}

fn upload_texture_pixels(texture: *TextureData, data: []const u8) !void {
    const byte_count = texture_byte_count(texture.width, texture.height);

    const staging_memory = try gfx.surface.device.allocateMemory(.{
        .allocation_size = .size(byte_count),
        .memory_type = .fcram_cached,
    }, null);
    defer gfx.surface.device.freeMemory(staging_memory, null);

    const staging_buffer = try gfx.surface.device.createBuffer(.{
        .size = .size(byte_count),
        .usage = .{
            .transfer_src = true,
        },
    }, null);
    defer gfx.surface.device.destroyBuffer(staging_buffer, null);
    try gfx.surface.device.bindBufferMemory(staging_buffer, staging_memory, .size(0));

    const texture_buffer = try gfx.surface.device.createBuffer(.{
        .size = .size(byte_count),
        .usage = .{
            .transfer_dst = true,
        },
    }, null);
    defer gfx.surface.device.destroyBuffer(texture_buffer, null);
    try gfx.surface.device.bindBufferMemory(texture_buffer, texture.memory, .size(0));
    const mapped = try gfx.surface.device.mapMemory(staging_memory, .size(0), .whole);
    defer gfx.surface.device.unmapMemory(staging_memory);
    convert_texture_data_tiled_abgr(mapped[0..byte_count], data[0..byte_count], texture.width, texture.height);
    try gfx.surface.device.flushMappedMemoryRanges(&.{.{
        .memory = staging_memory,
        .offset = .size(0),
        .size = .size(byte_count),
    }});
    try gfx.surface.queues.get(.transfer).copyBuffer(.{
        .src_buffer = staging_buffer,
        .src_offset = .size(0),
        .dst_buffer = texture_buffer,
        .dst_offset = .size(0),
        .size = .size(byte_count),
    });
    gfx.surface.device.waitIdle();
}

fn destroy_texture_data(texture: *TextureData) void {
    if (gfx.surface.device != .null) {
        if (texture.view != .null) {
            gfx.surface.device.destroyImageView(texture.view, null);
        }
        if (texture.image != .null) {
            gfx.surface.device.destroyImage(texture.image, null);
        }
        if (texture.memory != .null) {
            gfx.surface.device.freeMemory(texture.memory, null);
        }
    }
    texture.* = .{};
}

fn valid_texture_dimensions(width: u32, height: u32) bool {
    return width >= 8 and height >= 8 and
        width <= 1024 and height <= 1024 and
        std.math.isPowerOfTwo(width) and std.math.isPowerOfTwo(height);
}

fn texture_byte_count(width: u32, height: u32) u32 {
    return @intCast(@as(usize, width) * @as(usize, height) * TEX_BPP);
}

fn convert_texture_data_tiled_abgr(dst: []u8, src: []const u8, width: u32, height: u32) void {
    for (0..height) |y| {
        const yu: u32 = @intCast(y);
        const dst_y = height - 1 - yu;
        for (0..width) |x| {
            const xu: u32 = @intCast(x);
            const src_off = (@as(usize, yu) * width + xu) * TEX_BPP;
            const dst_off = tiled_pixel_offset(width, xu, dst_y);
            write_abgr8888(dst[dst_off..][0..TEX_BPP], src[src_off..][0..TEX_BPP]);
        }
    }
}

fn write_abgr8888(dst: []u8, src_rgba: []const u8) void {
    dst[0] = src_rgba[3];
    dst[1] = src_rgba[2];
    dst[2] = src_rgba[1];
    dst[3] = src_rgba[0];
}

fn tiled_pixel_offset(width: u32, x: u32, y: u32) usize {
    const tile_size = 8;
    const tile_pixels = tile_size * tile_size;
    const tile_x = x / tile_size;
    const tile_y = y / tile_size;
    const tiles_per_row = width / tile_size;
    const subtile_x: u3 = @intCast(x & (tile_size - 1));
    const subtile_y: u3 = @intCast(y & (tile_size - 1));
    const subtile = pica.morton.toIndex(u3, 2, .{ subtile_x, subtile_y });
    const pixel = (tile_y * tiles_per_row + tile_x) * tile_pixels + subtile;
    return @as(usize, pixel) * TEX_BPP;
}

fn external_memory(data: []const u8) mango.DeviceMemory {
    const start = std.mem.alignBackward(usize, @intFromPtr(data.ptr), PAGE_SIZE);
    const end = std.mem.alignForward(usize, @intFromPtr(data.ptr) + data.len, PAGE_SIZE);
    const physical = horizon.memory.toPhysical(start);

    const raw = ExternalMemoryData{
        .virtual_page_shifted = @intCast(start >> 12),
        .physical_page_shifted = @intCast(@intFromEnum(physical) >> 12),
        .size_page_shifted = @intCast((end - start) >> 12),
        .heap = .fcram,
    };
    return @enumFromInt(@as(u64, @bitCast(raw)));
}

fn page_offset(data: []const u8) usize {
    return @intFromPtr(data.ptr) & (PAGE_SIZE - 1);
}

fn is_linear_range(data: []const u8) bool {
    const start = @intFromPtr(data.ptr);
    const end = start + data.len;
    return (start >= horizon.memory.old_linear_heap_begin and end <= horizon.memory.old_linear_heap_end) or
        (start >= horizon.memory.linear_heap_begin and end <= horizon.memory.linear_heap_end);
}

fn float_to_u8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0);
}

fn unorm8_scale() f32 {
    return 1.0 / 255.0;
}

fn snorm16_scale() f32 {
    return 1.0 / 32767.0;
}
