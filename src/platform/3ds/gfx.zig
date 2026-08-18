//! Nintendo 3DS Mango backend.
//!
//! This follows the same ownership shape as the deko3D backend: the surface
//! owns the display device, while this module owns renderer state
//! and backend resources.

const std = @import("std");
const zitrus = @import("zitrus");
const gfx_api = @import("../gfx_api.zig");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const vertex = Rendering.vertex;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const gfx = @import("../gfx.zig");
const basic_vert align(@alignOf(u32)) = @embedFile("aether_basic_vert").*;

pub const mesh_source_mode = Mesh.SourceMode.borrowed_cpu;

const mango = zitrus.mango;
const pica = zitrus.hardware.pica;

const MAX_TEXTURES = 256;
const PAGE_SIZE = 4096;
const SCREEN_WIDTH: u32 = 400;
const SCREEN_HEIGHT: u32 = 240;
// The framebuffer is 480x400 and is later downsampled to 240x400.
// We're performing SSAA, which works on all consoles of the 3DS family
const FRAMEBUFFER_TOP_WIDTH = 480;
const FRAMEBUFFER_TOP_HEIGHT = 400;
const FRAMEBUFFER_BOTTOM_WIDTH = 240;
const FRAMEBUFFER_BOTTOM_HEIGHT = 320;
const COMMAND_BUFFER_COUNT = 2;
const FRAME_SYNC_TIMEOUT_NS = 2 * std.time.ns_per_s;
const TEX_BPP = 4;
const ALPHA_TEST_REFERENCE: u8 = 25;
const POS_SCALE: [4]f32 = .{ snorm16_scale(), snorm16_scale(), snorm16_scale(), 1.0 };
const UV_SCALE: [4]f32 = .{ snorm16_scale(), snorm16_scale(), 0.0, 0.0 };
const COLOR_SCALE: [4]f32 = .{ unorm8_scale(), unorm8_scale(), unorm8_scale(), unorm8_scale() };

const MeshData = struct {
    vertex: MeshBufferData = .{},
    index: MeshBufferData = .{},
    vertex_count: usize = 0,
    index_count: usize = 0,
};

const MeshBufferData = struct {
    memory: []const u8 = &.{},
    gpu_memory: mango.DeviceSlice = .empty,
    size: u32 = 0,
    capacity: u32 = 0,
};

const TextureData = struct {
    memory: []const u8 = &.{},
    gpu_memory: mango.DeviceSlice = .empty,
    image: mango.Image = .null,
    view: mango.ImageView = .null,
    width: u32 = 0,
    height: u32 = 0,
    alive: bool = false,
};

const PendingTextureUpload = struct {
    handle: Texture.Handle,
    data: []align(16) u8,
};

const RenderTarget = struct {
    color_memory: []const u8 = &.{},
    depth_memory: []const u8 = &.{},
    gpu_color_memory: mango.DeviceSlice = .empty,
    gpu_depth_memory: mango.DeviceSlice = .empty,
    color_image: mango.Image = .null,
    depth_image: mango.Image = .null,
    color_view: mango.ImageView = .null,
    depth_view: mango.ImageView = .null,
};

const CombinerMode = enum {
    invalid,
    primary,
    texture,
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

const ScreenState = struct {
    command_buffer: mango.CommandBuffer = .null,
    recording: bool = false,
    render_open: bool = false,
    bound_vertex_buffer: mango.DeviceSlice = .empty,
    bound_texture: Texture.Handle = .none,
    combiner_mode: CombinerMode = .invalid,

    fn reset_cache(state: *ScreenState) void {
        state.bound_vertex_buffer = .empty;
        state.bound_texture = .none;
        state.combiner_mode = .invalid;
    }
};

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

var meshes = Util.ResourceTable(MeshData, 8192, Mesh.Handle).init();
var texture_slots = Util.ResourceTable(TextureData, MAX_TEXTURES, Texture.Handle).init();
var retired_textures = Util.CircularBuffer(TextureData, MAX_TEXTURES * 2).init();
var retired_texture_overflow: std.ArrayList(TextureData) = .empty;
var pending_texture_uploads = Util.CircularBuffer(PendingTextureUpload, MAX_TEXTURES * 2).init();

pub var draw_state = DrawState{
    .mat = Mat4.identity(),
    .tex_id = 0,
};
var pending_state = ShaderState{
    .view = Mat4.identity(),
    .proj = Mat4.identity(),
};
var projection_uniform_rows: [4][4]f32 = mat4_to_uniform_rows(Mat4.identity());

var initialized = false;
var clear_color: [4]u8 = .{ 0, 0, 0, 255 };
var current_screen: gfx.Surface.Screen = .top;
var bottom_touched = false;
var bottom_presented = false;
var vsync_enabled = true;
var depth_write_enabled = true;
var culling_enabled = true;
var current_texture: Texture.Handle = .none;
var command_pool: mango.CommandPool = .null;
var command_buffers: [COMMAND_BUFFER_COUNT]mango.CommandBuffer = @splat(.null);
var top_frame_semaphore: mango.Semaphore = .null;
var bottom_frame_semaphore: mango.Semaphore = .null;
var texture_upload_semaphore: mango.Semaphore = .null;
var top_next_sync_value: u64 = 0;
var bottom_next_sync_value: u64 = 0;
var texture_upload_next_sync_value: u64 = 0;
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
var fog_lut: mango.FogLookupTable = .null;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

pub fn init() gfx_api.InitError!void {
    _ = render_io;
    command_pool = gfx.surface.device.createCommandPool(.{
        .initial_command_buffers = COMMAND_BUFFER_COUNT,
    }, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GfxInitFailed,
    };
    errdefer cleanup_renderer_resources();

    gfx.surface.device.allocateCommandBuffers(.{
        .pool = command_pool,
        .command_buffer_count = COMMAND_BUFFER_COUNT,
    }, &command_buffers) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GfxInitFailed,
    };
    top_state.command_buffer = command_buffers[0];
    bottom_state.command_buffer = command_buffers[1];

    fog_lut = gfx.surface.device.createFogLookupTable(.{}, null) catch return error.GfxInitFailed;
    basic_shader = gfx.surface.device.createShader(.init(.psh, &basic_vert, "main"), null) catch return error.GfxInitFailed;
    vertex_input = create_vertex_input() catch return error.GfxInitFailed;
    texture_sampler = gfx.surface.device.createSampler(.{
        .mag_filter = .nearest,
        .min_filter = .nearest,
        .mip_filter = .nearest,
        .address_mode_u = .repeat,
        .address_mode_v = .repeat,
        .lod_bias = 0.0,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = @splat(0),
    }, null) catch return error.GfxInitFailed;

    top_frame_semaphore = gfx.surface.device.createSemaphore(.initial_zero, null) catch return error.GfxInitFailed;
    errdefer {
        gfx.surface.device.destroySemaphore(top_frame_semaphore, null);
        top_frame_semaphore = .null;
    }
    bottom_frame_semaphore = gfx.surface.device.createSemaphore(.initial_zero, null) catch return error.GfxInitFailed;
    errdefer {
        gfx.surface.device.destroySemaphore(bottom_frame_semaphore, null);
        bottom_frame_semaphore = .null;
    }
    texture_upload_semaphore = gfx.surface.device.createSemaphore(.initial_zero, null) catch return error.GfxInitFailed;
    errdefer {
        gfx.surface.device.destroySemaphore(texture_upload_semaphore, null);
        texture_upload_semaphore = .null;
    }
    top_next_sync_value = 0;
    bottom_next_sync_value = 0;
    texture_upload_next_sync_value = 0;
    top_frame_wait = 0;
    bottom_frame_wait = 0;
    top_wait = 0;
    bottom_wait = 0;
    bottom_presented = false;

    top_target = create_render_target(.top) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GfxInitFailed,
    };
    errdefer destroy_render_target(&top_target);
    bottom_target = create_render_target(.bottom) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GfxInitFailed,
    };
    errdefer destroy_render_target(&bottom_target);

    update_projection_uniform_rows();

    initialized = true;
    set_vsync(gfx.sync);
}

pub fn deinit() void {
    if (!initialized) return;
    gfx.surface.device.waitIdle();
    submit_state_reset();
    destroy_all_meshes();
    destroy_all_textures();
    destroy_pending_texture_uploads();
    collect_retired_resources();
    retired_texture_overflow.deinit(render_alloc);
    retired_texture_overflow = .empty;
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
    if (draw_state.alpha_blend_enabled == @intFromBool(enabled)) return;
    draw_state.alpha_blend_enabled = @intFromBool(enabled);
    const state = screen_state(current_screen);
    if (initialized and state.recording) {
        state.command_buffer.setBlendEquation(normal_blend_equation());
        apply_alpha_test_state(state.command_buffer);
    }
}

pub fn set_depth_write(enabled: bool) void {
    if (depth_write_enabled == enabled) return;
    depth_write_enabled = enabled;
    const state = screen_state(current_screen);
    if (initialized and state.recording) {
        state.command_buffer.setDepthWriteEnable(depth_write_enabled);
    }
}

// NOTE: Fog is really inaccurate if not near, this is because the LUT has only 128 entries
// and we're using non-linear depth causing the relevant entries to fall within only
// 1 or 2 entries. This is amplified by using large far distances in the perspective projection.
//
// Either use non-linear depth (W-Buffering is supported), in which case the
// projection matrix must be changed for this (we don't control it here); or 
// have nearer far distances in the perspective projection.
pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    draw_state.fog_enabled = @intFromBool(enabled);
    draw_state.fog_start = start;
    draw_state.fog_end = end;
    draw_state.fog_color = .{ r, g, b };

    const state = screen_state(current_screen);
    if (initialized and state.recording) {
        state.command_buffer.setTextureCombinersEffect(if (enabled) .fog else .none);

        if (enabled) {
            state.command_buffer.setFogColor(&.{@trunc(r * 255), @trunc(g * 255), @trunc(b * 255)});

            // NOTE: Why? to recreate or destroy a LUT it must not be referenced by the command buffer.
            state.command_buffer.bindFogTable(.null);

            // HACK: hardcoded
            var ctx: FogTableContext = .{ .near = 0.1, .far = 256, .start = start, .end = end };
            gfx.surface.device.recreateFogLookupTable(fog_lut, .{
                .map = &FogTableContext.map,
                .context = &ctx,
            });
            state.command_buffer.bindFogTable(fog_lut);
        }
    }
}

const FogTableContext = struct {
    near: f32,
    far: f32,
    start: f32,
    end: f32,

    pub fn map(raw: ?*anyopaque, x: f32) callconv(.c) f32 {
        const ctx: *const FogTableContext = @alignCast(@ptrCast(raw));
        const z = ctx.far*ctx.near/((1.0-x)*(ctx.far-ctx.near)+ctx.near);
        return std.math.clamp((ctx.end-z)/(ctx.end-ctx.start), 0.0, 1.0);
    }
};

pub fn set_clip_planes(_: bool) void {}

pub fn set_culling(enabled: bool) void {
    if (culling_enabled == enabled) return;
    culling_enabled = enabled;
    const state = screen_state(current_screen);
    if (initialized and state.recording) {
        // Front face is CCW so we cull the CW faces.
        state.command_buffer.setCullMode(if (culling_enabled) .cw else .none);
    }
}

pub fn set_uv_offset(u: f32, v: f32) void {
    if (draw_state.uv_offset[0] == u and draw_state.uv_offset[1] == v) return;
    draw_state.uv_offset = .{ u, v };
    const state = screen_state(current_screen);
    if (initialized and state.recording) {
        upload_uv_uniform(state.command_buffer);
    }
}

pub fn set_proj_matrix(m: *const Mat4) void {
    pending_state.proj = m.*;
    update_projection_uniform_rows();
    const state = screen_state(current_screen);
    if (initialized and state.recording) {
        upload_projection_uniforms(state.command_buffer);
    }
}

pub fn set_view_matrix(m: *const Mat4) void {
    pending_state.view = m.*;
}

pub fn set_render_state(state: *const Rendering.RenderState) void {
    set_alpha_blend(state.blend == .alpha);
    set_depth_write(state.depth_write);
    set_culling(state.cull);
    set_clip_planes(state.clip_planes);
    set_uv_offset(state.uv_offset[0], state.uv_offset[1]);
    set_fog(state.fog.enabled, state.fog.start, state.fog.end, state.fog.color[0], state.fog.color[1], state.fog.color[2]);
    set_proj_matrix(&state.proj);
    set_view_matrix(&state.view);
    bind_texture(if (state.texture.is_null()) Texture.Default.handle else state.texture);
}

pub fn start_frame() bool {
    if (!initialized or gfx.surface.device == .null) return false;

    wait_for_frame_sync() catch |err| {
        std.log.err("3DS Mango frame wait failed: {s}", .{@errorName(err)});
        return false;
    };
    collect_retired_resources();
    drain_pending_texture_uploads();
    submit_state_reset();
    current_screen = .top;
    bottom_touched = false;
    top_wait = queue_clear_screen_color(.top, 0) catch |err| {
        std.log.err("3DS Mango top clear color failed: {s}", .{@errorName(err)});
        return false;
    };
    top_wait = queue_clear_screen_depth(.top, top_wait) catch |err| {
        std.log.err("3DS Mango top clear depth failed: {s}", .{@errorName(err)});
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
        bottom_wait = queue_clear_screen_color(.bottom, 0) catch |err| {
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

pub fn clear_depth() void {
    if (!initialized or gfx.surface.device == .null) return;

    const cmd = begin_screen_recording(current_screen) catch |err| {
        std.log.err("3DS Mango depth clear recording failed: {s}", .{@errorName(err)});
        return;
    };
    cmd.clearDepthStencilImage(&.{
        .subresource_range = .full,
        .image = render_target(current_screen).depth_image,
        .depth = 1.0,
        .stencil = 0,
    });
    // We must invalidate the gpu cache!
    cmd.memoryBarrier(.{ .render_attachments = true });
}

pub fn has_second_screen() bool {
    return true;
}

pub fn switch_second_screen() void {
    current_screen = .bottom;
    bottom_touched = true;
    bottom_wait = queue_clear_screen_color(.bottom, 0) catch |err| blk: {
        std.log.err("3DS Mango bottom clear failed: {s}", .{@errorName(err)});
        break :blk 0;
    };
}

pub fn set_vsync(v: bool) void {
    if (!initialized or gfx.surface.device == .null) {
        vsync_enabled = v;
        return;
    }
    if (vsync_enabled == v and gfx.surface.sync == v) return;

    submit_state_reset();
    wait_for_frame_sync() catch |err| {
        std.log.err("3DS Mango frame wait before vsync toggle failed: {s}", .{@errorName(err)});
        return;
    };
    gfx.surface.set_vsync(v) catch |err| {
        std.log.err("3DS Mango swapchain vsync toggle failed: {s}", .{@errorName(err)});
        return;
    };
    vsync_enabled = v;
    top_frame_wait = 0;
    bottom_frame_wait = 0;
    top_wait = 0;
    bottom_wait = 0;
    bottom_presented = false;
}

pub fn wait_for_borrowed_meshes() void {
    if (!initialized or gfx.surface.device == .null) return;

    wait_for_frame_sync() catch |err| {
        std.log.err("3DS Mango borrowed mesh wait failed: {s}; falling back to device idle", .{@errorName(err)});
        gfx.surface.device.waitIdle();
    };
}

pub fn create_mesh(_: *const Mesh.Desc) gfx_api.CreateMeshError!Mesh.Handle {
    return meshes.add(.{}) orelse error.OutOfMeshes;
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    if (handle.is_null()) return;
    const mesh = meshes.get_ptr(handle) orelse Util.panic_invalid_handle("3ds gfx", "destroy_mesh", handle);
    retire_mesh_data(mesh);
    _ = meshes.remove(handle);
}

pub fn update_mesh(handle: Mesh.Handle, desc: *const Mesh.UpdateDesc) void {
    const mesh = meshes.get_ptr(handle) orelse Util.panic_invalid_handle("3ds gfx", "update_mesh", handle);
    const data = desc.vertices;
    const indices = desc.indices;
    if (data.len == 0) {
        retire_mesh_data(mesh);
        return;
    }

    retire_mesh_data(mesh);
    mesh.vertex = create_mesh_buffer_data(data, "vertex") orelse return;
    const index_bytes = std.mem.sliceAsBytes(indices);
    if (index_bytes.len > 0) {
        mesh.index = create_mesh_buffer_data(index_bytes, "index") orelse {
            retire_mesh_data(mesh);
            return;
        };
    }
    mesh.vertex_count = data.len / vertex.Layout.stride;
    mesh.index_count = indices.len;
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4) void {
    const mesh = meshes.get_ptr(handle) orelse Util.panic_invalid_handle("3ds gfx", "draw_mesh", handle);
    if (mesh.vertex_count == 0) return;
    if (mesh.vertex_count > std.math.maxInt(usize) / vertex.Layout.stride) return;
    if (mesh.vertex_count * vertex.Layout.stride > mesh.vertex.size) return;

    draw_state.mat = model.*;

    const cmd = begin_screen_recording(current_screen) catch |err| {
        std.log.err("3DS Mango command recording failed: {s}", .{@errorName(err)});
        return;
    };

    upload_modelview_uniforms(cmd, model, &pending_state.view);

    const state = screen_state(current_screen);
    bind_draw_texture_state(state, cmd);

    if (state.bound_vertex_buffer != mesh.vertex.gpu_memory) {
        const buffers = [_]mango.DeviceSlice{mesh.vertex.gpu_memory};
        cmd.bindVertexBuffers(0, &buffers);
        state.bound_vertex_buffer = mesh.vertex.gpu_memory;
    }
    if (mesh.index_count > 0) {
        cmd.bindIndexBuffer(mesh.index.gpu_memory, .u16);
        cmd.drawIndexed(@intCast(mesh.index_count), 0, 0);
    } else {
        cmd.draw(@intCast(mesh.vertex_count), 0);
    }
}

fn create_mesh_buffer_data(data: []const u8, label: []const u8) ?MeshBufferData {
    if (data.len > std.math.maxInt(u32)) {
        std.log.err("3DS Mango {s} mesh update too large: {} bytes", .{ label, data.len });
        return null;
    }

    const capacity: u32 = @intCast(data.len);
    gfx.surface.device.flushCachedMemoryRanges(&.{data}) catch {};

    const gpu_memory = gfx.surface.device.hostToDevice(data) catch {
        std.log.err("3DS Mango {s} mesh update received non-linear memory; use std.process.Init.gpa for mesh storage", .{ label });
        return null;
    };

    return .{
        .memory = data,
        .gpu_memory = gpu_memory,
        .size = @intCast(data.len),
        .capacity = capacity,
    };
}

pub fn create_texture(desc: *const Texture.UploadDesc) gfx_api.CreateTextureError!Texture.Handle {
    const width = desc.width;
    const height = desc.height;
    const data = desc.pixels;
    if (!valid_texture_dimensions(width, height)) return error.UnsupportedTextureSize;
    if (data.len < @as(usize, width) * @as(usize, height) * 4) return error.TextureDataTooSmall;

    const handle = texture_slots.add(.{}) orelse return error.OutOfTextureSlots;
    const texture = texture_slots.get_ptr(handle) orelse return error.OutOfTextureSlots;
    errdefer {
        destroy_texture_data(texture);
        _ = texture_slots.remove(handle);
    }

    texture.* = .{
        .width = width,
        .height = height,
    };
    create_texture_resources(texture) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GfxInitFailed,
    };
    upload_texture_pixels(texture, data) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GfxInitFailed,
    };
    texture.alive = true;
    return handle;
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const texture = texture_slots.get_ptr(handle) orelse Util.panic_invalid_handle("3ds gfx", "update_texture", handle);
    if (!texture.alive) return;
    if (data.len < @as(usize, texture.width) * @as(usize, texture.height) * 4) return;

    if (gfx.frame_active) {
        queue_pending_texture_upload(handle, data) catch |err| {
            std.log.err("3DS Mango texture update queue failed: {s}", .{@errorName(err)});
        };
        return;
    }

    wait_for_frame_sync() catch |err| {
        std.log.err("3DS Mango texture update wait failed: {s}", .{@errorName(err)});
        return;
    };
    collect_retired_resources();
    upload_texture_pixels(texture, data) catch |err| {
        std.log.err("3DS Mango texture upload failed: {s}", .{@errorName(err)});
    };
}

pub fn bind_texture(handle: Texture.Handle) void {
    if (!handle.is_null()) {
        const texture = texture_slots.get(handle) orelse Util.panic_invalid_handle("3ds gfx", "bind_texture", handle);
        if (!texture.alive) return;
    }
    current_texture = handle;
    draw_state.tex_id = @intCast(texture_slots.raw_index(handle) orelse 0);
}

pub fn destroy_texture(handle: Texture.Handle) void {
    if (handle.is_null()) return;
    const texture = texture_slots.get_ptr(handle) orelse Util.panic_invalid_handle("3ds gfx", "destroy_texture", handle);
    drop_pending_texture_uploads(handle);
    retire_texture_data(texture);
    _ = texture_slots.remove(handle);
    if (current_texture == handle) current_texture = .none;
}

pub fn force_texture_resident(_: Texture.Handle) void {}

fn wait_for_frame_sync() !void {
    if (top_frame_wait != 0) {
        wait_for_screen_sync(.top, top_frame_wait) catch |err| {
            std.log.err("3DS Mango top frame semaphore wait stalled: target={} next={}", .{ top_frame_wait, top_next_sync_value });
            return err;
        };
    }
    if (bottom_frame_wait != 0) {
        wait_for_screen_sync(.bottom, bottom_frame_wait) catch |err| {
            std.log.err("3DS Mango bottom frame semaphore wait stalled: target={} next={}", .{ bottom_frame_wait, bottom_next_sync_value });
            return err;
        };
    }
}

fn wait_for_screen_sync(screen: gfx.Surface.Screen, wait_value: u64) !void {
    if (wait_value == 0) return;
    const semaphore = screen_semaphore(screen);
    try gfx.surface.device.waitSemaphores(.init(&.{semaphore}, &.{wait_value}), FRAME_SYNC_TIMEOUT_NS);
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

fn queue_clear_screen_color(screen: gfx.Surface.Screen, wait_value: u64) !u64 {
    const semaphore = screen_semaphore(screen);
    const signal_value = next_frame_sync_value(screen);
    const wait_op: ?mango.SemaphoreOperation = if (wait_value == 0)
        null
    else
        .init(semaphore, wait_value);
    const signal_op = mango.SemaphoreOperation.init(semaphore, signal_value);
    try gfx.surface.device.clearColorImage(if (wait_op) |*op| op else null, &signal_op, &.{
        .subresource_range = .full,
        .image = render_target(screen).color_image,
        .color = clear_color,
    });
    return signal_value;
}

fn queue_clear_screen_depth(screen: gfx.Surface.Screen, wait_value: u64) !u64 {
    const semaphore = screen_semaphore(screen);
    const signal_value = next_frame_sync_value(screen);
    const wait_op: ?mango.SemaphoreOperation = if (wait_value == 0)
        null
    else
        .init(semaphore, wait_value);
    const signal_op = mango.SemaphoreOperation.init(semaphore, signal_value);
    try gfx.surface.device.clearDepthStencilImage(if (wait_op) |*op| op else null, &signal_op, &.{
        .subresource_range = .full,
        .image = render_target(screen).depth_image,
        .depth = 1.0,
        .stencil = 0,
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
    state.reset_cache();
    cmd.bindShaders(&.{.vertex}, &.{basic_shader});
    set_default_graphics_state(cmd, screen, state);
    upload_projection_uniforms(cmd);
    upload_static_uniforms(cmd);
    cmd.beginRendering(.{
        .color_attachment = render_target(screen).color_view,
        .depth_stencil_attachment = render_target(screen).depth_view,
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
    const wait_op: ?mango.SemaphoreOperation = if (wait_value == 0)
        null
    else
        .init(semaphore, wait_value);
    const signal_op = mango.SemaphoreOperation.init(semaphore, signal_value);

    const cmd = state.command_buffer;
    if (state.render_open) {
        cmd.endRendering();
        state.render_open = false;
    }
    cmd.end() catch |err| {
        state.recording = false;
        cmd.reset(.none);
        return err;
    };
    errdefer {
        // Leave the screen state reusable if queue submission rejects the
        // executable buffer before the GPU sees it.
        state.recording = false;
        cmd.reset(.none);
    }
    try gfx.surface.device.submit(if (wait_op) |*op| op else null, &signal_op, &.{
        .command_buffer = cmd,
    });
    state.recording = false;
    return signal_value;
}

fn blit_screen_to_swapchain(screen: gfx.Surface.Screen, wait_value: u64) !u64 {
    const semaphore = screen_semaphore(screen);
    const signal_value = next_frame_sync_value(screen);
    const wait_op: ?mango.SemaphoreOperation = if (wait_value == 0)
        null
    else
        .init(semaphore, wait_value);
    const signal_op = mango.SemaphoreOperation.init(semaphore, signal_value);
    try gfx.surface.acquire(screen);
    try gfx.surface.device.blitImage(if (wait_op) |*op| op else null, &signal_op, &.{
        .src_image = render_target(screen).color_image,
        .dst_image = gfx.surface.current_image(screen),
        .src_subresource = .full,
        .dst_subresource = .full,
    });
    return signal_value;
}

fn set_default_graphics_state(cmd: mango.CommandBuffer, screen: gfx.Surface.Screen, state: *ScreenState) void {
    const dims = screen_dimensions(screen);
    const rect = mango.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{ .width = dims.width, .height = dims.height },
    };
    cmd.setDepthMode(.z_buffer);
    // Front face is CCW so we cull CW faces.
    cmd.setCullMode(if (culling_enabled) .cw else .none);
    cmd.setPrimitiveTopology(.triangle_list);
    cmd.setViewport(.{
        .rect = rect,
        .min_depth = 0.0,
        .max_depth = 1.0,
    });
    cmd.setScissor(.inside(rect));
    bind_primary_color_state(state, cmd);
    cmd.setBlendEquation(normal_blend_equation());
    cmd.setColorWriteMask(.rgba);
    cmd.setDepthTestEnable(true);
    cmd.setDepthCompareOp(.lt);
    cmd.setDepthWriteEnable(depth_write_enabled);
    cmd.setDepthBias(0.0);
    cmd.setLogicOpEnable(false);
    cmd.setLogicOp(.copy);
    apply_alpha_test_state(cmd);
    cmd.setStencilTestEnable(false);
    cmd.setStencilOp(.keep, .keep, .keep, .always);
    cmd.setStencilCompareMask(0xff);
    cmd.setStencilWriteMask(0xff);
    cmd.setStencilReference(0);
    cmd.setVertexInput(vertex_input);
    cmd.setTextureCoordinates(.@"2", .@"2");
    cmd.setTextureCombinersEffect(.none);
    cmd.setTextureCombinersEffectDepthFlip(false);
    cmd.setLightingEnable(false);
}

fn bind_draw_texture_state(state: *ScreenState, cmd: mango.CommandBuffer) void {
    const texture = texture_slots.get(current_texture) orelse {
        bind_primary_color_state(state, cmd);
        return;
    };
    if (!texture.alive or texture.view == .null or texture_sampler == .null) {
        bind_primary_color_state(state, cmd);
        return;
    }
    if (state.bound_texture != current_texture) {
        cmd.bindCombinedImageSamplers(0, &.{.{
            .image = texture.view,
            .sampler = texture_sampler,
        }});
        state.bound_texture = current_texture;
    }
    if (state.combiner_mode != .texture) {
        cmd.setTextureCombiners(5, &.{texture_color_combiner()});
        state.combiner_mode = .texture;
    }
}

fn bind_primary_color_state(state: *ScreenState, cmd: mango.CommandBuffer) void {
    if (!state.bound_texture.is_null()) {
        cmd.bindCombinedImageSamplers(0, &.{mango.CombinedImageSampler.none});
        state.bound_texture = .none;
    }
    if (state.combiner_mode != .primary) {
        cmd.setTextureCombiners(5, &.{primary_color_combiner()});
        state.combiner_mode = .primary;
    }
}

fn apply_alpha_test_state(cmd: mango.CommandBuffer) void {
    cmd.setAlphaTestEnable(draw_state.alpha_blend_enabled != 0);
    cmd.setAlphaTestCompareOp(.gt);
    cmd.setAlphaTestReference(ALPHA_TEST_REFERENCE);
}

fn normal_blend_equation() mango.ColorBlendEquation {
    return if (draw_state.alpha_blend_enabled != 0) .{
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
    };
}

fn keep_destination_blend_equation() mango.ColorBlendEquation {
    return .{
        .src_color_factor = .zero,
        .dst_color_factor = .one,
        .color_op = .add,
        .src_alpha_factor = .zero,
        .dst_alpha_factor = .one,
        .alpha_op = .add,
    };
}

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

fn update_projection_uniform_rows() void {
    projection_uniform_rows = mat4_to_uniform_rows(Mat4.mul(pending_state.proj, get_projection_transform()));
}

fn upload_projection_uniforms(cmd: mango.CommandBuffer) void {
    cmd.bindFloatUniforms(.vertex, 0, &projection_uniform_rows);
}

fn upload_modelview_uniforms(cmd: mango.CommandBuffer, model: *const Mat4, view: *const Mat4) void {
    var rows = mat4_to_uniform_rows(Mat4.mul(model.*, view.*));
    cmd.bindFloatUniforms(.vertex, 4, &rows);
}

fn upload_static_uniforms(cmd: mango.CommandBuffer) void {
    var uniforms = [_][4]f32{
        POS_SCALE,
        uv_uniform_row(),
        COLOR_SCALE,
    };
    cmd.bindFloatUniforms(.vertex, 8, &uniforms);
}

fn upload_uv_uniform(cmd: mango.CommandBuffer) void {
    var uniform = [_][4]f32{uv_uniform_row()};
    cmd.bindFloatUniforms(.vertex, 9, &uniform);
}

fn uv_uniform_row() [4]f32 {
    return .{ UV_SCALE[0], UV_SCALE[1], draw_state.uv_offset[0], draw_state.uv_offset[1] };
}

fn mat4_to_uniform_rows(mat: Mat4) [4][4]f32 {
    var out: [4][4]f32 = undefined;
    inline for (0..4) |row| {
        out[row] = .{ mat.data[0][row], mat.data[1][row], mat.data[2][row], mat.data[3][row] };
    }
    return out;
}

// We don't control the projection matrix so this transforms:
// - x, y -> rotates in clockwise direction
// - z -> [0, 1] to [0, -1]
fn get_projection_transform() Mat4 {
    return .{ .data = .{
        .{0, -1, 0, 0},
        .{1, 0, 0,  0},
        .{0, 0, -1, 0},
        .{0, 0, 0,  1},
    }};
}

fn screen_dimensions(screen: gfx.Surface.Screen) mango.Extent2D {
    return switch (screen) {
        .top => .{ .width = FRAMEBUFFER_TOP_WIDTH, .height = FRAMEBUFFER_TOP_HEIGHT },
        .bottom => .{ .width = FRAMEBUFFER_BOTTOM_WIDTH, .height = FRAMEBUFFER_BOTTOM_HEIGHT },
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
    state.reset_cache();
}

fn queue_pending_texture_upload(handle: Texture.Handle, data: []align(16) u8) !void {
    const texture = texture_slots.get(handle) orelse return;
    if (!texture.alive) return;

    const byte_count = texture_byte_count(texture.width, texture.height);
    const copy = try render_alloc.alignedAlloc(u8, .fromByteUnits(16), byte_count);
    errdefer render_alloc.free(copy);
    @memcpy(copy, data[0..byte_count]);

    _ = pending_texture_uploads.add_element(.{
        .handle = handle,
        .data = copy,
    }) orelse return error.PendingTextureQueueFull;
}

fn drain_pending_texture_uploads() void {
    for (pending_texture_uploads.buffer[1..]) |*maybe_upload| {
        if (maybe_upload.*) |upload| {
            if (texture_slots.get_ptr(upload.handle)) |texture| {
                if (texture.alive) {
                    upload_texture_pixels(texture, upload.data) catch |err| {
                        std.log.err("3DS Mango pending texture upload failed: {s}", .{@errorName(err)});
                    };
                }
            }
            render_alloc.free(upload.data);
            maybe_upload.* = null;
        }
    }
    pending_texture_uploads.clear();
}

fn drop_pending_texture_uploads(handle: Texture.Handle) void {
    for (pending_texture_uploads.buffer[1..], 1..) |*maybe_upload, i| {
        if (maybe_upload.*) |upload| {
            if (upload.handle == handle) {
                render_alloc.free(upload.data);
                maybe_upload.* = null;
                _ = pending_texture_uploads.remove_element(i);
            }
        }
    }
}

fn destroy_pending_texture_uploads() void {
    for (pending_texture_uploads.buffer[1..]) |*maybe_upload| {
        if (maybe_upload.*) |upload| {
            render_alloc.free(upload.data);
            maybe_upload.* = null;
        }
    }
    pending_texture_uploads.clear();
}

fn retire_mesh_data(mesh: *MeshData) void {
    mesh.* = .{};
    if (gfx.surface.device == .null) return;
}

fn retire_texture_data(texture: *TextureData) void {
    const retired = texture.*;
    texture.* = .{};
    if (retired.memory.len == 0 and retired.image == .null and retired.view == .null) return;
    if (gfx.surface.device == .null) return;

    if (retired_textures.add_element(retired) == null) {
        if (gfx.frame_active) {
            retired_texture_overflow.append(render_alloc, retired) catch |err| {
                std.log.err("3DS Mango retired texture overflow allocation failed; leaking texture: {s}", .{@errorName(err)});
            };
            return;
        }
        collect_retired_resources_after_sync();
        if (retired_textures.add_element(retired) == null) {
            gfx.surface.device.waitIdle();
            var immediate = retired;
            destroy_texture_data(&immediate);
        }
    }
}

fn collect_retired_resources_after_sync() void {
    if (gfx.surface.device == .null) return;
    if (gfx.frame_active) {
        gfx.surface.device.waitIdle();
    } else {
        wait_for_frame_sync() catch |err| {
            std.log.err("3DS Mango retired resource wait failed: {s}", .{@errorName(err)});
            gfx.surface.device.waitIdle();
        };
    }
    collect_retired_resources();
}

fn collect_retired_resources() void {
    if (gfx.surface.device == .null) return;

    for (retired_textures.buffer[1..]) |*maybe_texture| {
        if (maybe_texture.*) |*texture| {
            destroy_texture_data(texture);
            maybe_texture.* = null;
        }
    }
    retired_textures.clear();

    for (retired_texture_overflow.items) |*texture| {
        destroy_texture_data(texture);
    }
    retired_texture_overflow.clearRetainingCapacity();
}

fn cleanup_renderer_resources() void {
    if (gfx.surface.device == .null) return;

    destroy_render_target(&bottom_target);
    destroy_render_target(&top_target);

    if (fog_lut != .null) {
        gfx.surface.device.destroyFogLookupTable(fog_lut, null);
        fog_lut = .null;
    }
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
    if (texture_upload_semaphore != .null) {
        gfx.surface.device.destroySemaphore(texture_upload_semaphore, null);
        texture_upload_semaphore = .null;
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
    for (meshes.slots[1..]) |*maybe_mesh| {
        if (maybe_mesh.*) |*mesh| destroy_mesh_data(mesh);
        maybe_mesh.* = null;
    }
    meshes.clear();
}

fn destroy_all_textures() void {
    for (texture_slots.slots[1..]) |*maybe_texture| {
        if (maybe_texture.*) |*texture| destroy_texture_data(texture);
        maybe_texture.* = null;
    }
    texture_slots.clear();
    current_texture = .none;
    draw_state.tex_id = 0;
}

fn destroy_mesh_data(mesh: *MeshData) void {
    mesh.* = .{};
}

fn create_render_target(screen: gfx.Surface.Screen) !RenderTarget {
    const dims = screen_dimensions(screen);
    const pixel_count = @as(usize, dims.width) * @as(usize, dims.height);
    const color_byte_count: u32 = @intCast(mango.Format.a8b8g8r8_unorm.scale(pixel_count));
    const depth_byte_count: u32 = @intCast(mango.Format.d24_unorm_s8_uint.scale(pixel_count));

    const device = gfx.surface.device;
    var target = RenderTarget{};
    target.color_memory = try device.allocatePrivate(.a, color_byte_count);
    errdefer {
        device.freePrivate(target.color_memory);
        target.color_memory = &.{};
    }
    target.gpu_color_memory = try device.hostToDevice(target.color_memory);

    target.depth_memory = try device.allocatePrivate(.b, depth_byte_count);
    errdefer {
        device.freePrivate(target.depth_memory);
        target.depth_memory = &.{};
    }
    target.gpu_depth_memory = try device.hostToDevice(target.depth_memory);

    target.color_image = try device.createImage(.{
        .flags = .{},
        .tiling = .optimal,
        .usage = .{
            .color_attachment = true,
        },
        .extent = dims,
        .format = .a8b8g8r8_unorm,
        .mip_levels = .@"1",
        .array_layers = .@"1",
    }, null);
    errdefer {
        device.destroyImage(target.color_image, null);
        target.color_image = .null;
    }
    try device.bindImageMemory(target.color_image, target.gpu_color_memory);

    target.depth_image = try device.createImage(.{
        .flags = .{},
        .tiling = .optimal,
        .usage = .{
            .depth_stencil_attachment = true,
        },
        .extent = dims,
        .format = .d24_unorm_s8_uint,
        .mip_levels = .@"1",
        .array_layers = .@"1",
    }, null);
    errdefer {
        device.destroyImage(target.depth_image, null);
        target.depth_image = .null;
    }
    try device.bindImageMemory(target.depth_image, target.gpu_depth_memory);

    target.color_view = try device.createImageView(.{
        .type = .@"2d",
        .format = .a8b8g8r8_unorm,
        .image = target.color_image,
        .subresource_range = .full,
    }, null);
    errdefer {
        device.destroyImageView(target.color_view, null);
        target.color_view = .null;
    }

    target.depth_view = try device.createImageView(.{
        .type = .@"2d",
        .format = .d24_unorm_s8_uint,
        .image = target.depth_image,
        .subresource_range = .full,
    }, null);
    errdefer {
        device.destroyImageView(target.depth_view, null);
        target.depth_view = .null;
    }

    return target;
}

fn destroy_render_target(target: *RenderTarget) void {
    if (gfx.surface.device != .null) {
        if (target.depth_view != .null) {
            gfx.surface.device.destroyImageView(target.depth_view, null);
        }
        if (target.color_view != .null) {
            gfx.surface.device.destroyImageView(target.color_view, null);
        }
        if (target.depth_image != .null) {
            gfx.surface.device.destroyImage(target.depth_image, null);
        }
        if (target.color_image != .null) {
            gfx.surface.device.destroyImage(target.color_image, null);
        }
        if (target.depth_memory.len != 0) {
            gfx.surface.device.freePrivate(target.depth_memory);
        }
        if (target.color_memory.len != 0) {
            gfx.surface.device.freePrivate(target.color_memory);
        }
    }
    target.* = .{};
}

fn create_texture_resources(texture: *TextureData) !void {
    const byte_count = texture_byte_count(texture.width, texture.height);
    const device = gfx.surface.device;

    texture.memory = try device.allocatePrivate(.a, byte_count);
    errdefer {
        device.freePrivate(texture.memory);
        texture.memory = &.{};
        texture.gpu_memory = .empty;
    }
    texture.gpu_memory = try device.hostToDevice(texture.memory);

    texture.image = try device.createImage(.{
        .flags = .{},
        .tiling = .optimal,
        .usage = .{
            .sampled = true,
        },
        .extent = .{ .width = @intCast(texture.width), .height = @intCast(texture.height) },
        .format = .a8b8g8r8_unorm,
        .mip_levels = .@"1",
        .array_layers = .@"1",
    }, null);
    errdefer {
        device.destroyImage(texture.image, null);
        texture.image = .null;
    }

    try device.bindImageMemory(texture.image, texture.gpu_memory);

    texture.view = try device.createImageView(.{
        .type = .@"2d",
        .format = .a8b8g8r8_unorm,
        .image = texture.image,
        .subresource_range = .full,
    }, null);
}

fn upload_texture_pixels(texture: *TextureData, data: []const u8) !void {
    const device = gfx.surface.device;
    const byte_count = texture_byte_count(texture.width, texture.height);

    // XXX: This allocator is slow!
    const fcram = device.hostAllocator();

    const staging = try fcram.alloc(u8, byte_count);
    defer fcram.free(staging);

    const gpu_staging = try device.hostToDevice(staging);

    // XXX: Try u32 reversal (CPU, more cache friendly than swizzling) + copyBufferToImage (GPU) for large textures? (larger than 64x16)
    convert_texture_data_tiled_abgr(staging, data[0..byte_count], texture.width, texture.height);

    try device.flushCachedMemoryRanges(&.{staging});
    texture_upload_next_sync_value += 1;
    const signal_op = mango.SemaphoreOperation.init(texture_upload_semaphore, texture_upload_next_sync_value);
    try device.copyBuffer(null, &signal_op, &.{
        .src_buffer = gpu_staging.slice(0, byte_count),
        .dst_buffer = texture.gpu_memory.slice(0, byte_count),
    });
    try device.waitSemaphores(.init(&.{texture_upload_semaphore}, &.{texture_upload_next_sync_value}), FRAME_SYNC_TIMEOUT_NS);
}

fn destroy_texture_data(texture: *TextureData) void {
    if (gfx.surface.device != .null) {
        if (texture.view != .null) {
            gfx.surface.device.destroyImageView(texture.view, null);
        }
        if (texture.image != .null) {
            gfx.surface.device.destroyImage(texture.image, null);
        }
        if (texture.memory.len != 0) {
            gfx.surface.device.freePrivate(texture.memory);
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
    const dst_words: []u32 = @ptrCast(@alignCast(dst));
    const src_words: []const u32 = @ptrCast(@alignCast(src));

    for (0..height) |y| {
        const yu: u32 = @intCast(y);
        const dst_y = height - 1 - yu;
        for (0..width) |x| {
            const xu: u32 = @intCast(x);
            const src_off = (@as(usize, yu) * width + xu);
            const dst_off = tiled_pixel_offset(width, xu, dst_y);
            write_abgr8888(&dst_words[dst_off], &src_words[src_off]);
        }
    }
}

fn write_abgr8888(dst: *u32, src_rgba: *const u32) void {
    dst.* = @byteSwap(src_rgba.*);
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
    return @as(usize, pixel);
}

fn float_to_u8(v: f32) u8 {
    return @intFromFloat(std.math.clamp(v, 0.0, 1.0) * 255.0);
}

fn float_to_snorm16(v: f32) i16 {
    return @intFromFloat(std.math.clamp(v, -1.0, 1.0) * 32767.0);
}

fn unorm8_scale() f32 {
    return 1.0 / 255.0;
}

fn snorm16_scale() f32 {
    return 1.0 / 32767.0;
}
