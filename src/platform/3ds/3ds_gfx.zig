//! Mango/libctru graphics backend for Nintendo 3DS.

const std = @import("std");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const surface = @import("surface.zig");
const shaders = @import("aether_shaders");
const zitrus = @import("zitrus");
const mango = zitrus.mango;
const pica = zitrus.hardware.pica;

const c = @cImport({
    @cDefine("wint_t", "unsigned int");
    @cInclude("3ds/types.h");
    @cInclude("3ds/gpu/enums.h");
    @cInclude("3ds/gpu/gpu.h");
    @cInclude("3ds/gpu/gx.h");
    @cInclude("3ds/os.h");
    @cInclude("3ds/services/gspgpu.h");
    @cInclude("3ds/gfx.h");
    @cInclude("3ds/allocator/vram.h");
});

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

const SCREEN_WIDTH: u32 = 400;
const SCREEN_HEIGHT: u32 = 240;
const TARGET_WIDTH: u16 = 240;
const TARGET_HEIGHT: u16 = 400;
const MESH_SLOT_COUNT: usize = 2;
const MAX_DEFERRED_MESH_FREES: usize = 4096;
const MAX_TEXTURE_SIZE: u32 = 1024;
const MIN_TEXTURE_SIZE: u32 = 8;
const TEX_BPP: usize = 4;
const CACHE_LINE_SIZE: usize = 32;
const OS_FCRAM_VADDR: usize = 0x30000000;
const OS_FCRAM_SIZE: usize = 0x10000000;
const OS_OLD_FCRAM_VADDR: usize = 0x14000000;
const OS_OLD_FCRAM_SIZE: usize = 0x08000000;

const DISPLAY_TRANSFER_FLAGS: u32 = @intCast(
    c.GX_TRANSFER_FLIP_VERT(0) |
        c.GX_TRANSFER_OUT_TILED(0) |
        c.GX_TRANSFER_RAW_COPY(0) |
        c.GX_TRANSFER_IN_FORMAT(c.GX_TRANSFER_FMT_RGBA8) |
        c.GX_TRANSFER_OUT_FORMAT(c.GX_TRANSFER_FMT_RGB8) |
        c.GX_TRANSFER_SCALING(c.GX_TRANSFER_SCALE_NO),
);

fn gx_buffer_dim(width: u16, height: u16) u32 {
    return (@as(u32, height) << 16) | @as(u32, width);
}

const VERTEX_STRIDE: usize = @sizeOf(Rendering.Vertex);
const POS_SCALE: [4]f32 = .{ snorm16_scale(), snorm16_scale(), snorm16_scale(), 1.0 };
const UV_SCALE: [2]f32 = .{ snorm16_scale(), snorm16_scale() };
const COLOR_SCALE: [4]f32 = .{ unorm8_scale(), unorm8_scale(), unorm8_scale(), unorm8_scale() };

comptime {
    std.debug.assert(VERTEX_STRIDE == 16);
    std.debug.assert(@offsetOf(Rendering.Vertex, "pos") == 0);
    std.debug.assert(@offsetOf(Rendering.Vertex, "color") == 8);
    std.debug.assert(@offsetOf(Rendering.Vertex, "uv") == 12);
}

const PipelineData = struct {
    shader: mango.Shader,
    vertex_input: mango.VertexInputLayout,
    sampler: mango.Sampler,
};

const RenderTargetData = struct {
    color_memory: mango.DeviceMemory,
    depth_memory: mango.DeviceMemory,
    color_image: mango.Image,
    depth_image: mango.Image,
    color_view: mango.ImageView,
    depth_view: mango.ImageView,
    color_pixels: []u8,
};

const MeshData = struct {
    slots: [MESH_SLOT_COUNT]MeshSlot = .{ .{}, .{} },
    latest_slot: ?usize = null,
    len: usize,
};

const MeshSlot = struct {
    memory: mango.DeviceMemory = .null,
    buffer: mango.Buffer = .null,
    mapped: []u8 = &.{},
    len: usize = 0,
    capacity: usize = 0,
    in_flight: bool = false,
    used_this_frame: bool = false,
};

const DeferredMeshFree = struct {
    memory: mango.DeviceMemory,
    buffer: mango.Buffer,
};

const TextureData = struct {
    width: u32,
    height: u32,
    upload_mode: TextureUploadMode,
    memory: mango.DeviceMemory,
    image: mango.Image,
    view: mango.ImageView,
};

const TextureUploadMode = enum {
    cpu_tiled,
    transfer_tiled,
};

const texenv_primary: mango.TextureCombinerUnit = .{
    .color_src = @splat(.primary_color),
    .alpha_src = @splat(.primary_color),
    .color_factor = @splat(.src_color),
    .alpha_factor = @splat(.src_alpha),
    .color_op = .replace,
    .alpha_op = .replace,
    .color_scale = .@"1x",
    .alpha_scale = .@"1x",
    .constant = @splat(0xFF),
};

const texenv_texture_modulate_primary: mango.TextureCombinerUnit = .{
    .color_src = .{ .primary_color, .texture_0, .primary_color },
    .alpha_src = .{ .primary_color, .texture_0, .primary_color },
    .color_factor = @splat(.src_color),
    .alpha_factor = @splat(.src_alpha),
    .color_op = .modulate,
    .alpha_op = .modulate,
    .color_scale = .@"1x",
    .alpha_scale = .@"1x",
    .constant = @splat(0xFF),
};

const texenv_untextured = [_]mango.TextureCombinerUnit{
    texenv_primary,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
};

const texenv_textured = [_]mango.TextureCombinerUnit{
    texenv_primary,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    mango.TextureCombinerUnit.previous,
    texenv_texture_modulate_primary,
};

const texenv_buffer_sources = [_]mango.TextureCombinerUnit.BufferSources{
    .previous,
    .previous,
    .previous,
    .previous,
};

const FogState = struct {
    enabled: bool = false,
    start: f32 = 0.0,
    end: f32 = 1.0,
    color: [4]u8 = .{ 0, 0, 0, 255 },
    table: [128]u32 = @splat(0),
};

var meshes = Util.CircularBuffer(MeshData, 2048).init();
var deferred_mesh_frees = Util.CircularBuffer(DeferredMeshFree, MAX_DEFERRED_MESH_FREES + 1).init();
var textures = Util.CircularBuffer(TextureData, 64).init();

var device: mango.Device = .null;
var submit_queue: mango.Queue = .null;
var fill_queue: mango.Queue = .null;
var command_pool: mango.CommandPool = .null;
var command_buffer: mango.CommandBuffer = .null;
var render_pipeline: PipelineData = undefined;
var render_target: RenderTargetData = undefined;
var render_pipeline_initialized = false;
var render_target_initialized = false;
var command_resources_initialized = false;

var projection_transform: Mat4 = Mat4.identity();
var initialized = false;
var frame_started = false;
var vsync_enabled = true;
var clear_color: [4]u8 = .{ 0, 0, 0, 255 };
var alpha_blend_enabled = true;
var depth_write_enabled = true;
var cull_face_enabled = true;
var fog_state: FogState = .{};
var uv_offset: [2]f32 = .{ 0.0, 0.0 };
var proj_matrix: Mat4 = Mat4.identity();
var view_matrix: Mat4 = Mat4.identity();
var default_texture: Texture.Handle = 0;
var bound_texture: Texture.Handle = 0;

pub fn init() anyerror!void {
    _ = render_io;

    c.gfxInitDefault();
    errdefer c.gfxExit();

    device = try mango.createAetherCtruBackedDevice(.{ .linear_gpa = render_alloc }, render_alloc);
    errdefer {
        device.destroy();
        device = .null;
    }

    submit_queue = device.getQueue(.submit);
    fill_queue = device.getQueue(.fill);

    try init_command_resources();
    errdefer deinit_command_resources();

    try init_render_target();
    errdefer deinit_render_target();

    render_pipeline = try init_pipeline();
    render_pipeline_initialized = true;
    errdefer {
        deinit_pipeline(&render_pipeline);
        render_pipeline_initialized = false;
    }

    init_projection_transform();
    initialized = true;
    frame_started = false;
}

pub fn deinit() void {
    if (surface.is_system_closing()) {
        abandon_service_resources();
        return;
    }

    frame_started = false;
    if (initialized and device != .null) device.waitIdle();
    release_completed_mesh_slots();
    free_deferred_mesh_slots();

    for (1..textures.buffer.len) |i| {
        if (textures.buffer[i]) |*tex| free_texture(tex);
    }
    textures.clear();

    if (render_pipeline_initialized) {
        deinit_pipeline(&render_pipeline);
        render_pipeline_initialized = false;
    }

    for (1..meshes.buffer.len) |i| {
        if (meshes.buffer[i]) |*mesh| free_mesh_slots(mesh);
    }
    meshes.clear();

    deinit_render_target();
    deinit_command_resources();

    if (device != .null) {
        device.destroy();
        device = .null;
    }

    if (initialized) {
        c.gfxExit();
        initialized = false;
    }
}

pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    clear_color = .{
        float_to_u8(r),
        float_to_u8(g),
        float_to_u8(b),
        float_to_u8(a),
    };
}

pub fn set_alpha_blend(enabled: bool) void {
    alpha_blend_enabled = enabled;
    if (frame_started) apply_dynamic_state();
}

pub fn set_depth_write(enabled: bool) void {
    depth_write_enabled = enabled;
    if (frame_started) apply_dynamic_state();
}

pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    fog_state.enabled = enabled;
    fog_state.start = start;
    fog_state.end = end;
    fog_state.color = .{ float_to_u8(r), float_to_u8(g), float_to_u8(b), 255 };
    rebuild_fog_table();
}

pub fn set_clip_planes(_: bool) void {}

pub fn set_culling(enabled: bool) void {
    cull_face_enabled = enabled;
    if (frame_started) apply_dynamic_state();
}

pub fn set_uv_offset(u: f32, v: f32) void {
    uv_offset = .{ u, v };
}

pub fn set_proj_matrix(mat: *const Mat4) void {
    proj_matrix = mat.*;
}

pub fn set_view_matrix(mat: *const Mat4) void {
    view_matrix = mat.*;
}

pub fn start_frame() bool {
    if (surface.is_system_closing()) return false;
    if (!initialized or frame_started) return false;

    release_completed_mesh_slots();
    free_deferred_mesh_slots();

    frame_started = true;
    clear_frame_targets() catch {
        frame_started = false;
        return false;
    };
    begin_command_buffer() catch {
        frame_started = false;
        return false;
    };
    return true;
}

pub fn end_frame() void {
    if (!frame_started) return;
    if (surface.is_system_closing()) {
        frame_started = false;
        return;
    }

    mark_current_frame_mesh_slots_in_flight();
    finish_command_buffer() catch {
        frame_started = false;
        return;
    };
    present_render_target();
    frame_started = false;
}

pub fn clear_depth() void {
    if (!frame_started) return;

    finish_command_buffer() catch {
        frame_started = false;
        return;
    };
    clear_depth_target() catch {
        frame_started = false;
        return;
    };
    begin_command_buffer() catch {
        frame_started = false;
        return;
    };
}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
}

pub fn create_mesh() anyerror!Mesh.Handle {
    const handle = meshes.add_element(.{
        .len = 0,
    }) orelse return error.OutOfMeshes;

    return @intCast(handle);
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    if (surface.is_system_closing()) {
        _ = meshes.remove_element(handle);
        return;
    }

    if (mesh_slot(handle)) |mesh| {
        free_mesh_slots(mesh);
    }
    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    if (surface.is_system_closing()) return;

    const mesh = mesh_slot(handle) orelse return;
    if (data.len > std.math.maxInt(u32)) {
        std.debug.panic("3ds_gfx: mesh vertex data is too large to flush", .{});
    }

    if (data.len == 0) {
        mesh.latest_slot = null;
        mesh.len = 0;
        return;
    }

    const slot_idx = select_upload_slot(mesh) orelse
        std.debug.panic("3ds_gfx: update_mesh called while both 3DS mesh upload slots are in use", .{});
    const slot = &mesh.slots[slot_idx];
    ensure_mesh_slot_capacity(slot, data.len) catch
        std.debug.panic("3ds_gfx: out of linear memory for mesh upload", .{});

    @memcpy(slot.mapped[0..data.len], data);
    slot.len = data.len;
    flush_memory(slot.memory, data.len) catch {};

    mesh.latest_slot = slot_idx;
    mesh.len = data.len;
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize) void {
    if (surface.is_system_closing()) return;
    if (!frame_started or !render_pipeline_initialized) return;

    const mesh = mesh_slot(handle) orelse return;
    const slot_idx = mesh.latest_slot orelse return;
    const slot = &mesh.slots[slot_idx];
    if (count == 0 or slot.len == 0 or slot.buffer == .null) return;

    const needed = mesh_draw_bytes_needed(count) orelse return;
    if (needed > slot.len) return;

    upload_draw_uniforms(model);
    bind_current_texture();
    command_buffer.setAetherFog(fog_state.enabled, fog_state.color, if (fog_state.enabled) &fog_state.table else &.{});
    command_buffer.bindVertexBuffersSlice(0, &.{slot.buffer}, &.{0});

    slot.used_this_frame = true;
    command_buffer.draw(@intCast(@min(count, std.math.maxInt(u32))), 0);
}

pub fn create_texture(width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle {
    try validate_texture(width, height, data);

    var tex = try create_texture_resources(width, height);
    errdefer free_texture(&tex);

    try upload_texture_data(&tex, data[0..texture_size(width, height)]);

    const handle: Texture.Handle = @intCast(textures.add_element(tex) orelse return error.OutOfTextures);
    if (default_texture == 0) default_texture = handle;
    return handle;
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    if (surface.is_system_closing()) return;

    const tex = texture_slot(handle) orelse return;
    const size = texture_size(tex.width, tex.height);
    if (data.len < size) return;

    upload_texture_data(tex, data[0..size]) catch return;
    if (frame_started and bound_texture == handle) bind_current_texture();
}

pub fn bind_texture(handle: Texture.Handle) void {
    if (surface.is_system_closing()) return;
    bound_texture = handle;
    if (frame_started) bind_current_texture();
}

pub fn destroy_texture(handle: Texture.Handle) void {
    if (surface.is_system_closing()) {
        if (bound_texture == handle) bound_texture = 0;
        if (default_texture == handle) default_texture = 0;
        _ = textures.remove_element(handle);
        return;
    }

    if (texture_slot(handle)) |tex| free_texture(tex);
    if (bound_texture == handle) bound_texture = 0;
    if (default_texture == handle) default_texture = 0;
    _ = textures.remove_element(handle);
    if (frame_started) bind_current_texture();
}

pub fn force_texture_resident(_: Texture.Handle) void {}

fn init_command_resources() !void {
    command_pool = try device.createCommandPool(.no_preheat, null);
    errdefer {
        device.destroyCommandPool(command_pool, null);
        command_pool = .null;
    }

    var buffers: [1]mango.CommandBuffer = undefined;
    try device.allocateCommandBuffers(.{
        .pool = command_pool,
        .command_buffer_count = buffers.len,
    }, &buffers);
    command_buffer = buffers[0];
    command_resources_initialized = true;
}

fn deinit_command_resources() void {
    if (!command_resources_initialized or device == .null) return;
    if (command_buffer != .null) {
        device.freeCommandBuffers(command_pool, &.{command_buffer});
        command_buffer = .null;
    }
    if (command_pool != .null) {
        device.destroyCommandPool(command_pool, null);
        command_pool = .null;
    }
    command_resources_initialized = false;
}

fn init_render_target() !void {
    const color_size = mango.Format.a8b8g8r8_unorm.scale(@as(usize, TARGET_WIDTH) * TARGET_HEIGHT);
    const depth_size = mango.Format.d24_unorm_s8_uint.scale(@as(usize, TARGET_WIDTH) * TARGET_HEIGHT);

    const color_memory = try device.allocateMemory(.{
        .memory_type = .vram_a,
        .allocation_size = .size(@intCast(color_size)),
    }, null);
    errdefer device.freeMemory(color_memory, null);

    const depth_memory = try device.allocateMemory(.{
        .memory_type = .vram_b,
        .allocation_size = .size(@intCast(depth_size)),
    }, null);
    errdefer device.freeMemory(depth_memory, null);

    const color_image = try device.createImage(.{
        .flags = .{},
        .type = .@"2d",
        .tiling = .optimal,
        .usage = .{ .transfer_src = true, .color_attachment = true },
        .extent = .{ .width = TARGET_WIDTH, .height = TARGET_HEIGHT },
        .format = .a8b8g8r8_unorm,
        .mip_levels = .@"1",
        .array_layers = .@"1",
    }, null);
    errdefer device.destroyImage(color_image, null);
    try device.bindImageMemory(color_image, color_memory, .size(0));

    const depth_image = try device.createImage(.{
        .flags = .{},
        .type = .@"2d",
        .tiling = .optimal,
        .usage = .{ .depth_stencil_attachment = true },
        .extent = .{ .width = TARGET_WIDTH, .height = TARGET_HEIGHT },
        .format = .d24_unorm_s8_uint,
        .mip_levels = .@"1",
        .array_layers = .@"1",
    }, null);
    errdefer device.destroyImage(depth_image, null);
    try device.bindImageMemory(depth_image, depth_memory, .size(0));

    const color_view = try device.createImageView(.{
        .type = .@"2d",
        .format = .a8b8g8r8_unorm,
        .image = color_image,
        .subresource_range = .full,
    }, null);
    errdefer device.destroyImageView(color_view, null);

    const depth_view = try device.createImageView(.{
        .type = .@"2d",
        .format = .d24_unorm_s8_uint,
        .image = depth_image,
        .subresource_range = .full,
    }, null);
    errdefer device.destroyImageView(depth_view, null);

    const color_pixels = try device.mapMemory(color_memory, .size(0), .whole);

    render_target = .{
        .color_memory = color_memory,
        .depth_memory = depth_memory,
        .color_image = color_image,
        .depth_image = depth_image,
        .color_view = color_view,
        .depth_view = depth_view,
        .color_pixels = color_pixels,
    };
    render_target_initialized = true;
}

fn deinit_render_target() void {
    if (!render_target_initialized or device == .null) return;
    device.unmapMemory(render_target.color_memory);
    device.destroyImageView(render_target.depth_view, null);
    device.destroyImageView(render_target.color_view, null);
    device.destroyImage(render_target.depth_image, null);
    device.destroyImage(render_target.color_image, null);
    device.freeMemory(render_target.depth_memory, null);
    device.freeMemory(render_target.color_memory, null);
    render_target_initialized = false;
}

fn init_pipeline() !PipelineData {
    const code: []const u8 = &shaders.basic_vert;
    const shader = try device.createShader(.init(.psh, code, "main"), null);
    errdefer device.destroyShader(shader, null);

    const bindings = [_]mango.VertexInputBindingDescription{
        .{ .stride = VERTEX_STRIDE },
    };
    const attributes = [_]mango.VertexInputAttributeDescription{
        .{ .location = .v0, .binding = .@"0", .format = .r16g16b16a16_sscaled, .offset = 0 },
        .{ .location = .v1, .binding = .@"0", .format = .r8g8b8a8_uscaled, .offset = 8 },
        .{ .location = .v2, .binding = .@"0", .format = .r16g16_sscaled, .offset = 12 },
    };
    const vertex_input = try device.createVertexInputLayout(.init(&bindings, &attributes, &.{}), null);
    errdefer device.destroyVertexInputLayout(vertex_input, null);

    const sampler = try device.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mip_filter = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .lod_bias = 0.0,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .{ 0, 0, 0, 0 },
    }, null);

    return .{
        .shader = shader,
        .vertex_input = vertex_input,
        .sampler = sampler,
    };
}

fn deinit_pipeline(pl: *PipelineData) void {
    device.destroySampler(pl.sampler, null);
    device.destroyVertexInputLayout(pl.vertex_input, null);
    device.destroyShader(pl.shader, null);
}

fn clear_frame_targets() !void {
    try fill_queue.clearColorImage(.{
        .image = render_target.color_image,
        .color = clear_color,
        .subresource_range = .full,
    });
    try clear_depth_target();
}

fn clear_depth_target() !void {
    try fill_queue.clearDepthStencilImage(.{
        .image = render_target.depth_image,
        .depth = 1.0,
        .stencil = 0,
        .subresource_range = .full,
    });
}

fn begin_command_buffer() !void {
    try command_buffer.begin();
    command_buffer.bindShaders(&.{.vertex}, &.{render_pipeline.shader});
    command_buffer.setVertexInput(render_pipeline.vertex_input);
    command_buffer.setLightingEnable(false);
    command_buffer.setLightEnvironmentEnable(.{});
    command_buffer.setLogicOpEnable(false);
    command_buffer.setAlphaTestEnable(false);
    command_buffer.setStencilTestEnable(false);
    command_buffer.setDepthTestEnable(true);
    command_buffer.setDepthMode(.z_buffer);
    command_buffer.setDepthCompareOp(.lt);
    command_buffer.setPrimitiveTopology(.triangle_list);
    command_buffer.setFrontFace(.ccw);
    command_buffer.setColorWriteMask(.rgba);
    command_buffer.setViewport(.{
        .rect = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = TARGET_WIDTH, .height = TARGET_HEIGHT } },
        .min_depth = 0.0,
        .max_depth = 1.0,
    });
    command_buffer.setScissor(.inside(.{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = TARGET_WIDTH, .height = TARGET_HEIGHT },
    }));
    apply_dynamic_state();
    bind_current_texture();
    command_buffer.beginRendering(.{
        .color_attachment = render_target.color_view,
        .depth_stencil_attachment = render_target.depth_view,
    });
}

fn finish_command_buffer() !void {
    command_buffer.endRendering();
    try command_buffer.end();
    try submit_queue.submit(.{ .command_buffer = command_buffer });
    device.waitIdle();
}

fn present_render_target() void {
    var fb_width: u16 = 0;
    var fb_height: u16 = 0;
    const framebuffer = c.gfxGetFramebuffer(c.GFX_TOP, c.GFX_LEFT, &fb_width, &fb_height) orelse return;

    _ = c.GX_DisplayTransfer(
        @ptrCast(@alignCast(render_target.color_pixels.ptr)),
        gx_buffer_dim(TARGET_WIDTH, TARGET_HEIGHT),
        @ptrCast(@alignCast(framebuffer)),
        gx_buffer_dim(TARGET_WIDTH, TARGET_HEIGHT),
        DISPLAY_TRANSFER_FLAGS,
    );
    c.gspWaitForEvent(c.GSPGPU_EVENT_PPF, false);
    if (vsync_enabled) c.gspWaitForEvent(c.GSPGPU_EVENT_VBlank0, true);
    c.gfxSwapBuffers();
}

fn apply_dynamic_state() void {
    command_buffer.setDepthWriteEnable(depth_write_enabled);
    command_buffer.setCullMode(if (cull_face_enabled) .back else .none);
    command_buffer.setBlendEquation(if (alpha_blend_enabled) .{
        .src_color_factor = .src_alpha,
        .dst_color_factor = .one_minus_src_alpha,
        .color_op = .add,
        .src_alpha_factor = .one,
        .dst_alpha_factor = .one_minus_src_alpha,
        .alpha_op = .add,
    } else .{
        .src_color_factor = .one,
        .dst_color_factor = .zero,
        .color_op = .add,
        .src_alpha_factor = .one,
        .dst_alpha_factor = .zero,
        .alpha_op = .add,
    });
}

fn bind_current_texture() void {
    if (!frame_started) return;

    const effective_texture = if (bound_texture != 0) bound_texture else default_texture;
    if (effective_texture == 0) {
        command_buffer.bindCombinedImageSamplers(0, &.{mango.CombinedImageSampler.none});
        bind_texenv(false);
        return;
    }

    const tex = texture_slot(effective_texture) orelse {
        command_buffer.bindCombinedImageSamplers(0, &.{mango.CombinedImageSampler.none});
        bind_texenv(false);
        return;
    };

    command_buffer.bindCombinedImageSamplers(0, &.{.{
        .image = tex.view,
        .sampler = render_pipeline.sampler,
    }});
    bind_texenv(true);
}

fn bind_texenv(textured: bool) void {
    const stages = if (textured) &texenv_textured else &texenv_untextured;
    command_buffer.setTextureCombiners(stages, &texenv_buffer_sources);
}

fn upload_draw_uniforms(model: *const Mat4) void {
    var projection_rows = mat4_to_uniform_rows(Mat4.mul(proj_matrix, projection_transform));
    var model_view_rows = mat4_to_uniform_rows(Mat4.mul(model.*, view_matrix));
    var uniforms: [11][4]f32 = undefined;
    @memcpy(uniforms[0..4], projection_rows[0..4]);
    @memcpy(uniforms[4..8], model_view_rows[0..4]);
    uniforms[8] = POS_SCALE;
    uniforms[9] = .{ UV_SCALE[0], UV_SCALE[1], uv_offset[0], uv_offset[1] };
    uniforms[10] = COLOR_SCALE;
    command_buffer.bindFloatUniforms(.vertex, 0, &uniforms);
}

fn mat4_to_uniform_rows(mat: Mat4) [4][4]f32 {
    var out: [4][4]f32 = undefined;
    inline for (0..4) |row| {
        out[row] = .{ mat.data[0][row], mat.data[1][row], mat.data[2][row], mat.data[3][row] };
    }
    return out;
}

fn init_projection_transform() void {
    projection_transform = Mat4.mul(logical_viewport_transform(), ortho_tilt(0.0, @floatFromInt(SCREEN_WIDTH), 0.0, @floatFromInt(SCREEN_HEIGHT), 0.0, 1.0));
}

fn logical_viewport_transform() Mat4 {
    return .{ .data = .{
        .{ @as(f32, @floatFromInt(SCREEN_WIDTH)) * 0.5, 0.0, 0.0, 0.0 },
        .{ 0.0, @as(f32, @floatFromInt(SCREEN_HEIGHT)) * 0.5, 0.0, 0.0 },
        .{ 0.0, 0.0, -1.0, 0.0 },
        .{ @as(f32, @floatFromInt(SCREEN_WIDTH)) * 0.5, @as(f32, @floatFromInt(SCREEN_HEIGHT)) * 0.5, 1.0, 1.0 },
    } };
}

// Aether Mat4 uses row-vector multiplication. This is Citro3D's
// Mtx_OrthoTilt transposed into that convention; mat4_to_uniform_rows()
// transposes it back for the PICA shader's matrix * vector dp4 sequence.
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

fn select_upload_slot(mesh: *const MeshData) ?usize {
    if (mesh.latest_slot) |idx| {
        const slot = mesh.slots[idx];
        if (!slot.in_flight and !slot.used_this_frame) return idx;
    }

    for (0..MESH_SLOT_COUNT) |idx| {
        const slot = mesh.slots[idx];
        if (!slot.in_flight and !slot.used_this_frame) return idx;
    }

    return null;
}

fn ensure_mesh_slot_capacity(slot: *MeshSlot, len: usize) !void {
    if (slot.capacity >= len and slot.buffer != .null) return;

    free_mesh_slot(slot);

    const cap = std.mem.alignForward(usize, @max(len, 256), CACHE_LINE_SIZE);
    const memory = try device.allocateMemory(.{
        .memory_type = .fcram_cached,
        .allocation_size = .size(@intCast(cap)),
    }, null);
    errdefer device.freeMemory(memory, null);

    const buffer = try device.createBuffer(.{
        .size = .size(@intCast(cap)),
        .usage = .{ .vertex_buffer = true },
    }, null);
    errdefer device.destroyBuffer(buffer, null);

    try device.bindBufferMemory(buffer, memory, .size(0));
    const mapped = try device.mapMemory(memory, .size(0), .whole);
    if (!is_linear_fcram(mapped.ptr, mapped.len)) {
        std.debug.panic("3ds_gfx: mesh upload slots must be allocated in linear FCRAM", .{});
    }

    slot.* = .{
        .memory = memory,
        .buffer = buffer,
        .mapped = mapped,
        .capacity = cap,
        .len = 0,
    };
}

fn free_mesh_slots(mesh: *MeshData) void {
    for (&mesh.slots) |*slot| free_mesh_slot(slot);
    mesh.latest_slot = null;
    mesh.len = 0;
}

fn free_mesh_slot(slot: *MeshSlot) void {
    if (slot.buffer != .null or slot.memory != .null) {
        if (slot.in_flight or slot.used_this_frame) {
            defer_mesh_free(.{ .memory = slot.memory, .buffer = slot.buffer });
        } else {
            destroy_mesh_resources(slot.memory, slot.buffer);
        }
    }
    slot.* = .{};
}

fn destroy_mesh_resources(memory: mango.DeviceMemory, buffer: mango.Buffer) void {
    if (buffer != .null) device.destroyBuffer(buffer, null);
    if (memory != .null) {
        device.unmapMemory(memory);
        device.freeMemory(memory, null);
    }
}

fn defer_mesh_free(free: DeferredMeshFree) void {
    if (deferred_mesh_frees.add_element(free) != null) return;
    std.debug.panic("3ds_gfx: deferred mesh free queue exhausted", .{});
}

fn free_deferred_mesh_slots() void {
    for (1..deferred_mesh_frees.buffer.len) |i| {
        if (deferred_mesh_frees.buffer[i]) |free| {
            destroy_mesh_resources(free.memory, free.buffer);
        }
    }
    deferred_mesh_frees.clear();
}

fn release_completed_mesh_slots() void {
    for (1..meshes.buffer.len) |i| {
        if (meshes.buffer[i]) |*mesh| {
            for (&mesh.slots) |*slot| {
                slot.in_flight = false;
                slot.used_this_frame = false;
            }
        }
    }
}

fn abandon_service_resources() void {
    frame_started = false;
    initialized = false;
    render_pipeline_initialized = false;
    render_target_initialized = false;
    command_resources_initialized = false;
    device = .null;
    submit_queue = .null;
    fill_queue = .null;
    default_texture = 0;
    bound_texture = 0;
    meshes.clear();
    textures.clear();
    deferred_mesh_frees.clear();
}

fn mark_current_frame_mesh_slots_in_flight() void {
    for (1..meshes.buffer.len) |i| {
        if (meshes.buffer[i]) |*mesh| {
            for (&mesh.slots) |*slot| {
                if (slot.used_this_frame) {
                    slot.in_flight = true;
                    slot.used_this_frame = false;
                }
            }
        }
    }
}

fn mesh_draw_bytes_needed(count: usize) ?usize {
    if (count == 0) return 0;
    if (count > std.math.maxInt(usize) / VERTEX_STRIDE) return null;
    return count * VERTEX_STRIDE;
}

fn create_texture_resources(width: u32, height: u32) !TextureData {
    const size = texture_size(width, height);
    const upload_mode = texture_upload_mode(width, height);
    // 3DSX launchers can map VRAM read-only for the CPU. Keep texture
    // storage in linear FCRAM; PICA can still sample it by physical address,
    // and the transfer queue can still write tiled output here.
    const memory = try device.allocateMemory(.{
        .memory_type = .fcram_cached,
        .allocation_size = .size(size),
    }, null);
    errdefer device.freeMemory(memory, null);

    const image = try device.createImage(.{
        .flags = .{},
        .type = .@"2d",
        .tiling = .optimal,
        .usage = .{ .sampled = true, .transfer_dst = true },
        .extent = .{ .width = @intCast(width), .height = @intCast(height) },
        .format = .a8b8g8r8_unorm,
        .mip_levels = .@"1",
        .array_layers = .@"1",
    }, null);
    errdefer device.destroyImage(image, null);
    try device.bindImageMemory(image, memory, .size(0));

    const view = try device.createImageView(.{
        .type = .@"2d",
        .format = .a8b8g8r8_unorm,
        .image = image,
        .subresource_range = .full,
    }, null);

    return .{
        .width = width,
        .height = height,
        .upload_mode = upload_mode,
        .memory = memory,
        .image = image,
        .view = view,
    };
}

fn free_texture(tex: *TextureData) void {
    device.destroyImageView(tex.view, null);
    device.destroyImage(tex.image, null);
    device.freeMemory(tex.memory, null);
}

fn validate_texture(width: u32, height: u32, data: []align(16) u8) !void {
    if (width < MIN_TEXTURE_SIZE or height < MIN_TEXTURE_SIZE) {
        Util.engine_logger.err("3ds_gfx: texture {d}x{d} is too small; 3DS requires at least {d}x{d}", .{
            width,
            height,
            MIN_TEXTURE_SIZE,
            MIN_TEXTURE_SIZE,
        });
        return error.TextureTooSmall;
    }
    if (width > MAX_TEXTURE_SIZE or height > MAX_TEXTURE_SIZE) {
        Util.engine_logger.err("3ds_gfx: texture {d}x{d} is too large; 3DS limit is {d}x{d}", .{
            width,
            height,
            MAX_TEXTURE_SIZE,
            MAX_TEXTURE_SIZE,
        });
        return error.TextureTooLarge;
    }
    if (!std.math.isPowerOfTwo(width) or !std.math.isPowerOfTwo(height)) {
        Util.engine_logger.err("3ds_gfx: texture {d}x{d} is unsupported; 3DS textures require power-of-two dimensions", .{ width, height });
        return error.UnsupportedTextureSize;
    }

    const size = texture_size(width, height);
    if (data.len < size) return error.InsufficientData;
}

fn upload_texture_data(tex: *TextureData, data: []align(16) const u8) !void {
    switch (tex.upload_mode) {
        .cpu_tiled => return upload_texture_data_cpu(tex, data),
        .transfer_tiled => return upload_texture_data_transfer(tex, data),
    }
}

fn upload_texture_data_cpu(tex: *TextureData, data: []align(16) const u8) !void {
    const mapped = try device.mapMemory(tex.memory, .size(0), .whole);
    defer device.unmapMemory(tex.memory);

    @memset(mapped, 0);
    convert_texture_data_tiled_abgr(mapped, data, tex.width, tex.height);
    try flush_memory(tex.memory, mapped.len);
    device.waitIdle();
}

fn upload_texture_data_transfer(tex: *TextureData, data: []align(16) const u8) !void {
    const size = texture_size(tex.width, tex.height);

    const staging_memory = try device.allocateMemory(.{
        .memory_type = .fcram_cached,
        .allocation_size = .size(size),
    }, null);
    defer device.freeMemory(staging_memory, null);

    const staging_buffer = try device.createBuffer(.{
        .size = .size(size),
        .usage = .{ .transfer_src = true },
    }, null);
    defer device.destroyBuffer(staging_buffer, null);
    try device.bindBufferMemory(staging_buffer, staging_memory, .size(0));

    const mapped = try device.mapMemory(staging_memory, .size(0), .size(size));
    defer device.unmapMemory(staging_memory);

    convert_texture_data_linear_abgr(mapped, data, tex.width, tex.height);
    try flush_memory(staging_memory, mapped.len);

    try device.getQueue(.transfer).copyBufferToImage(.{
        .src_buffer = staging_buffer,
        .src_offset = .size(0),
        .dst_image = tex.image,
        .dst_subresource = .full,
    });
    device.waitIdle();
}

fn convert_texture_data_tiled_abgr(dst: []u8, src: []align(16) const u8, width: u32, height: u32) void {
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

fn convert_texture_data_linear_abgr(dst: []u8, src: []align(16) const u8, width: u32, height: u32) void {
    for (0..height) |y| {
        const yu: u32 = @intCast(y);
        const src_y = height - 1 - yu;
        for (0..width) |x| {
            const xu: u32 = @intCast(x);
            const src_off = (@as(usize, src_y) * width + xu) * TEX_BPP;
            const dst_off = (@as(usize, yu) * width + xu) * TEX_BPP;
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

fn texture_upload_mode(width: u32, height: u32) TextureUploadMode {
    _ = width;
    _ = height;
    // The CPU Morton path matches the sampled texture layout. The GX transfer
    // path is tempting for larger textures, but currently corrupts uploads
    // while small CPU-tiled textures render correctly.
    return .cpu_tiled;
}

fn texture_size(width: u32, height: u32) u32 {
    return @intCast(@as(usize, width) * height * TEX_BPP);
}

fn rebuild_fog_table() void {
    const safe_end = if (fog_state.end <= fog_state.start) fog_state.start + 0.001 else fog_state.end;
    var values: [129]f32 = undefined;
    for (&values, 0..) |*value, i| {
        const t = @as(f32, @floatFromInt(i)) / 128.0;
        const distance = fog_state.start + (safe_end - fog_state.start) * t;
        const fog = std.math.clamp((distance - fog_state.start) / (safe_end - fog_state.start), 0.0, 1.0);
        value.* = fog;
    }

    for (&fog_state.table, 0..) |*raw, i| {
        const current = values[i];
        const next = values[i + 1];
        const lut_value = pica.Graphics.TextureCombiners.FogLutValue{
            .value = .ofSaturating(current),
            .next_difference = .ofSaturating(next - current),
        };
        raw.* = @bitCast(zitrus.hardware.LsbRegister(pica.Graphics.TextureCombiners.FogLutValue).init(lut_value));
    }
}

fn flush_memory(memory: mango.DeviceMemory, len: usize) !void {
    try device.flushMappedMemoryRanges(&.{.{
        .memory = memory,
        .offset = .size(0),
        .size = .size(@intCast(len)),
    }});
}

fn mesh_slot(handle: Mesh.Handle) ?*MeshData {
    const idx: usize = handle;
    if (idx == 0 or idx >= meshes.buffer.len) return null;
    if (meshes.buffer[idx]) |*mesh| return mesh;
    return null;
}

fn texture_slot(handle: Texture.Handle) ?*TextureData {
    const idx: usize = handle;
    if (idx == 0 or idx >= textures.buffer.len) return null;
    if (textures.buffer[idx]) |*tex| return tex;
    return null;
}

fn unorm8_scale() f32 {
    return 1.0 / 255.0;
}

fn snorm16_scale() f32 {
    return 1.0 / 32767.0;
}

fn float_to_u8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0);
}

fn is_linear_fcram(ptr: [*]const u8, len: usize) bool {
    const start = @intFromPtr(ptr);
    return in_range(start, len, OS_FCRAM_VADDR, OS_FCRAM_SIZE) or
        in_range(start, len, OS_OLD_FCRAM_VADDR, OS_OLD_FCRAM_SIZE);
}

fn in_range(start: usize, len: usize, base: usize, size: usize) bool {
    if (start < base) return false;
    const offset = start - base;
    return offset <= size and len <= size - offset;
}
