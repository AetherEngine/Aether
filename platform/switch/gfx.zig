//! Nintendo Switch deko3d backend.
//!
//! The shape intentionally tracks the desktop Vulkan backend: context owns the
//! device/queue, swapchain owns frame/depth/command resources, and this file
//! owns renderer state plus backend resource records.

const std = @import("std");
const assert = std.debug.assert;
const Util = @import("../util/util.zig");
const Mat4 = @import("math").Mat4;
const Graphics = @import("../graphics/graphics.zig");
const vertex = Graphics.vertex;
const Mesh = Graphics.mesh;
const Texture = Graphics.texture;
const gfx = @import("../gfx.zig");
const basic_vert align(@alignOf(u32)) = @embedFile("aether_basic_vert").*;
const basic_frag align(@alignOf(u32)) = @embedFile("aether_basic_frag").*;

const dk = @import("deko.zig");
const Context = @import("context.zig");
const Swapchain = @import("swapchain.zig");
const GarbageCollector = @import("garbage_collector.zig");
const MeshHeap = @import("mesh_heap.zig");
const math = @import("math");

pub const mesh_source_mode = Mesh.SourceMode.uploaded_copy;

const code_mem_size = 512 * 1024;
const upload_cmd_mem_size = 64 * 1024;
const max_vertex_attribs = 32;
const max_vertex_buffers = 16;
const max_textures = 256;
const uniform_slots = 4096;
const uniform_stride: u32 = dk.alignForward(@intCast(@sizeOf(DrawUniform)), dk.UniformBufferAlignment);
const uniform_frame_size: u32 = uniform_stride * uniform_slots;
const image_descriptor_tables_per_frame = 128;
const image_descriptor_table_size: u32 = dk.alignForward(max_textures * dk.ImageDescriptorSize, dk.ImageDescriptorAlignment);
const image_descriptor_frame_size: u32 = image_descriptor_table_size * image_descriptor_tables_per_frame;

const PipelineData = struct {
    vertex_shader: dk.DkShader,
    fragment_shader: dk.DkShader,
    attribs: [max_vertex_attribs]dk.DkVtxAttribState,
    attrib_count: u32,
    vtx_buffers: [max_vertex_buffers]dk.DkVtxBufferState,
    vtx_buffer_count: u32,
};

const MeshBuffer = struct {
    range: MeshHeap.Range = .{},
    gpu_addr: dk.DkGpuAddr = 0,
    size: u32 = 0,
};

const MeshData = struct {
    vertex: MeshBuffer = .{},
    index: MeshBuffer = .{},
    vertex_count: usize = 0,
    index_count: usize = 0,
};

const TextureData = struct {
    mem_block: dk.DkMemBlock = null,
    image: dk.DkImage = undefined,
    view: dk.DkImageView = undefined,
    width: u32 = 0,
    height: u32 = 0,
    alive: bool = false,
};

const RetiredTextureSlot = struct {
    handle: Texture.Handle,
    retire_after_completed_frames: u64,
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

const DrawUniform = extern struct {
    model: [4][4]f32,
    view: [4][4]f32,
    proj: [4][4]f32,
    texture_index: u32,
    fog_enabled: u32,
    fog_start: f32,
    fog_end: f32,
    fog_color: [3]f32,
    alpha_blend_enabled: u32,
    uv_offset: [2]f32,
};

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

pub var context: Context = undefined;
pub var swapchain: Swapchain = undefined;
pub var gc: GarbageCollector = undefined;
var mesh_heap: MeshHeap = undefined;

var code_mem: dk.DkMemBlock = null;
var code_offset: u32 = 0;
var upload_command_mem: dk.DkMemBlock = null;
var upload_command_buffer: dk.DkCmdBuf = null;
var uniform_mem: dk.DkMemBlock = null;
var uniform_gpu_addr: dk.DkGpuAddr = 0;
var descriptor_mem: dk.DkMemBlock = null;
var descriptor_cpu_addr: ?[*]u8 = null;
var image_descriptor_base_gpu_addr: dk.DkGpuAddr = 0;
var sampler_descriptor_gpu_addr: dk.DkGpuAddr = 0;
var sampler_descriptor_offset: u32 = 0;
var image_descriptors: [max_textures]dk.DkImageDescriptor = @splat(.{ ._storage = @splat(0) });
var image_descriptor_count: u32 = 1;
var image_descriptors_dirty = true;
var image_descriptor_table_indices: [Swapchain.max_frames]u32 = @splat(0);

var meshes = Util.ResourceTableType(MeshData, 32768, Mesh.Handle).init();
var texture_slots = Util.ResourceTableType(TextureData, max_textures, Texture.Handle).init();
var retired_texture_slots: std.ArrayList(RetiredTextureSlot) = .empty;
var render_pipeline: PipelineData = undefined;
var render_pipeline_initialized = false;

pub var draw_state = DrawState{
    .mat = Mat4.identity(),
    .tex_id = 0,
};
var pending_state = ShaderState{
    .view = Mat4.identity(),
    .proj = Mat4.identity(),
};

var initialized = false;
var clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
var vsync_enabled = true;
var depth_write_enabled = true;
var depth_test_enabled = true;
var culling_enabled = true;
var alpha_blend_enabled = true;
var current_texture: Texture.Handle = .none;
var next_uniform_slot: u32 = 0;
var frame_draw_calls: u32 = 0;
var frame_vertex_count: u32 = 0;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

pub fn init() gfx.InitError!void {
    _ = render_io;
    context = Context.init(render_alloc) catch |err| switch (err) {
        else => return error.GfxInitFailed,
    };
    context.activate();
    errdefer context.deinit();

    swapchain = Swapchain.init(&context, gfx.sync) catch return error.GfxInitFailed;
    errdefer swapchain.deinit();

    gc = GarbageCollector.init(render_alloc, &context);
    errdefer gc.deinit();
    mesh_heap = MeshHeap.init(render_alloc, &context);
    gc.mesh_heap = &mesh_heap;
    errdefer mesh_heap.deinit();

    create_code_memory() catch return error.GfxInitFailed;
    errdefer destroy_code_memory();

    create_uniform_memory() catch return error.GfxInitFailed;
    errdefer destroy_uniform_memory();

    create_upload_command_buffer() catch return error.GfxInitFailed;
    errdefer destroy_upload_command_buffer();

    create_descriptor_memory() catch return error.GfxInitFailed;
    errdefer destroy_descriptor_memory();

    initialize_sampler_descriptor() catch return error.GfxInitFailed;
    render_pipeline = init_pipeline(vertex.Layout) catch |err| switch (err) {
        error.InvalidShader => return error.InvalidShader,
        error.OutOfShaderMemory => return error.OutOfShaderMemory,
        error.UnsupportedVertexLayout => return error.UnsupportedVertexLayout,
        else => return error.GfxInitFailed,
    };
    render_pipeline_initialized = true;

    create_fallback_texture() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.GfxInitFailed,
    };
    errdefer destroy_all_textures();

    initialized = true;
    set_vsync(vsync_enabled);
}

pub fn deinit() void {
    if (!initialized) return;

    context.wait_idle("switch gfx deinit");
    destroy_region_ring();
    destroy_all_meshes();
    mesh_heap.deinit();
    destroy_all_textures();
    retired_texture_slots.deinit(render_alloc);
    retired_texture_slots = .empty;
    gc.collect_all();

    render_pipeline_initialized = false;
    destroy_descriptor_memory();
    destroy_upload_command_buffer();
    destroy_uniform_memory();
    destroy_code_memory();
    gc.deinit();
    swapchain.deinit();
    context.deinit();

    initialized = false;
}

pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    clear_color = .{ r, g, b, a };
}

fn set_alpha_blend(enabled: bool) void {
    draw_state.alpha_blend_enabled = @intFromBool(enabled);
    if (enabled == alpha_blend_enabled) return;
    alpha_blend_enabled = enabled;
    if (initialized and swapchain.recording) bind_color_state();
}

fn set_depth_write(enabled: bool) void {
    if (enabled == depth_write_enabled) return;
    depth_write_enabled = enabled;
    if (initialized and swapchain.recording) bind_depth_state();
}

fn set_depth_test(enabled: bool) void {
    if (enabled == depth_test_enabled) return;
    depth_test_enabled = enabled;
    if (initialized and swapchain.recording) bind_depth_state();
}

fn set_fog(enabled: bool, _: f32, _: f32, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    draw_state.fog_enabled = @intFromBool(enabled);
    draw_state.fog_start = start;
    draw_state.fog_end = end;
    draw_state.fog_color = .{ r, g, b };
}

fn set_clip_planes(_: bool) void {}

fn set_culling(enabled: bool) void {
    if (enabled == culling_enabled) return;
    culling_enabled = enabled;
    if (initialized and swapchain.recording) bind_rasterizer_state();
}

fn set_uv_offset(u: f32, v: f32) void {
    draw_state.uv_offset = .{ u, v };
}

fn set_proj_matrix(m: *const Mat4) void {
    pending_state.proj = m.*;
}

fn set_view_matrix(m: *const Mat4) void {
    pending_state.view = m.*;
}

pub fn set_render_state(state: *const Graphics.RenderState) void {
    set_alpha_blend(state.blend == .alpha);
    set_depth_write(state.depth_write);
    set_depth_test(state.depth_test);
    set_culling(state.cull);
    set_clip_planes(state.clip_planes);
    set_uv_offset(state.uv_offset[0], state.uv_offset[1]);
    set_fog(state.fog.enabled, state.fog.near, state.fog.far, state.fog.start, state.fog.end, state.fog.color[0], state.fog.color[1], state.fog.color[2]);
    set_proj_matrix(&state.proj);
    set_view_matrix(&state.view);
    bind_texture(state.texture);
}

pub fn start_frame() bool {
    if (!initialized) return false;
    if (!swapchain.begin_frame(&gc)) return false;
    collect_retired_texture_slots();

    next_uniform_slot = 0;
    frame_draw_calls = 0;
    frame_vertex_count = 0;

    swapchain.bind_render_targets_and_clear(&clear_color);
    image_descriptor_table_indices[swapchain.frame_index] = 0;
    publish_image_descriptors_for_frame(swapchain.frame_index);
    image_descriptors_dirty = false;
    bind_current_image_descriptor_set();
    dk.dkCmdBufBindSamplerDescriptorSet(swapchain.command_buffer, sampler_descriptor_gpu_addr, 1);
    bind_fixed_state();
    context.mark_gpu(swapchain.command_buffer, .descriptors);
    return true;
}

pub fn end_frame() void {
    if (!initialized) return;
    _ = swapchain.end_frame();
}

pub fn clear_depth() void {
    if (!initialized or !swapchain.recording) return;
    dk.dkCmdBufClearDepthStencil(swapchain.command_buffer, true, 1.0, 0xFF, 0);
}

pub fn has_second_screen() bool {
    return false;
}

pub fn switch_second_screen() void {
    std.debug.panic("switch gfx: switch_second_screen called but this backend has no second screen", .{});
}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
    if (initialized) swapchain.set_vsync(v);
}

pub fn create_mesh(_: *const Mesh.Desc) gfx.CreateMeshError!Mesh.Handle {
    return meshes.add(.{}) orelse return error.OutOfMeshes;
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    if (handle.is_null()) return;
    const mesh = meshes.get_ptr(handle) orelse Util.panic_invalid_handle("switch gfx", "destroy_mesh", handle);
    destroy_mesh_data(mesh, true);
    _ = meshes.remove(handle);
}

pub fn update_mesh(handle: Mesh.Handle, desc: *const Mesh.UpdateDesc) void {
    const mesh = meshes.get_ptr(handle) orelse Util.panic_invalid_handle("switch gfx", "update_mesh", handle);
    const data = desc.vertices;
    const indices = desc.indices;
    const in_flight = swapchain.pending_frame_mask();

    upload_mesh_buffer(&mesh.vertex, data, in_flight) catch {
        mesh.vertex_count = 0;
        mesh.index_count = 0;
        return;
    };
    upload_mesh_buffer(&mesh.index, std.mem.sliceAsBytes(indices), in_flight) catch {
        mesh.vertex_count = 0;
        mesh.index_count = 0;
        return;
    };
    mesh.vertex_count = data.len / vertex.Layout.stride;
    mesh.index_count = indices.len;
    l2_invalidate_pending = true;
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4) void {
    const mesh = meshes.get_ptr(handle) orelse Util.panic_invalid_handle("switch gfx", "draw_mesh", handle);
    draw_mesh_range(handle, model, 0, @intCast(if (mesh.index_count > 0) mesh.index_count else mesh.vertex_count));
}

pub fn draw_mesh_range(handle: Mesh.Handle, model: *const Mat4, first: u32, count: u32) void {
    if (!initialized or !render_pipeline_initialized or !swapchain.recording) return;
    const mesh = meshes.get_ptr(handle) orelse Util.panic_invalid_handle("switch gfx", "draw_mesh_range", handle);
    if (count == 0) return;
    assert(@as(usize, first) + count <= (if (mesh.index_count > 0) mesh.index_count else mesh.vertex_count));
    const mesh_id = handle.raw_index();
    const frame_index = swapchain.frame_index;
    if (l2_invalidate_pending) {
        dk.dkCmdBufBarrier(swapchain.command_buffer, dk.BarrierFull, dk.InvalidateL2Cache);
        l2_invalidate_pending = false;
    }

    const buffer = mesh.vertex;
    if (buffer.range.mem_block == null or buffer.size == 0 or mesh.vertex_count == 0) return;
    const vertex_stride = vertex.Layout.stride;
    if (mesh.vertex_count > std.math.maxInt(usize) / vertex_stride) {
        Util.engine_logger.err("Switch draw rejected: vertex byte count overflow mesh={d} count={d} stride={d}", .{ mesh_id, mesh.vertex_count, vertex_stride });
        return;
    }
    const required_vertex_bytes = mesh.vertex_count * vertex_stride;
    if (required_vertex_bytes > buffer.size) {
        Util.engine_logger.err(
            "Switch draw rejected: mesh={d} count={d} stride={d} requires={d} available={d} frame={d} image={d}",
            .{ mesh_id, mesh.vertex_count, vertex_stride, required_vertex_bytes, buffer.size, frame_index, swapchain.image_index },
        );
        return;
    }
    if (mesh.index_count > 0 and mesh.index.size < mesh.index_count * @sizeOf(Mesh.Index)) return;

    ensure_image_descriptors_current();
    const texture_id = resolve_texture_index(draw_state.tex_id);

    context.mark_gpu_draw(
        swapchain.command_buffer,
        .draw_begin,
        @intCast(frame_index),
        @intCast(swapchain.image_index),
        frame_draw_calls,
        @intCast(mesh_id),
        count,
        texture_id,
        buffer.size,
        next_uniform_slot,
    );
    draw_state.mat = model.*;
    const pl = &render_pipeline;
    const shaders = [_]*const dk.DkShader{ &pl.vertex_shader, &pl.fragment_shader };
    dk.dkCmdBufBindShaders(swapchain.command_buffer, dk.StageGraphicsMask, shaders[0..].ptr, shaders.len);

    if (!bind_draw_uniform(texture_id)) return;
    const texture_handle = [_]dk.DkResHandle{dk.makeTextureHandle(texture_id, 0)};
    dk.dkCmdBufBindTextures(swapchain.command_buffer, dk.StageFragment, 1, texture_handle[0..].ptr, texture_handle.len);
    dk.dkCmdBufBindVtxAttribState(swapchain.command_buffer, pl.attribs[0..].ptr, pl.attrib_count);
    dk.dkCmdBufBindVtxBufferState(swapchain.command_buffer, pl.vtx_buffers[0..].ptr, pl.vtx_buffer_count);

    var extents: [max_vertex_buffers]dk.DkBufExtents = undefined;
    for (extents[0..pl.vtx_buffer_count]) |*extent| {
        extent.* = .{ .addr = buffer.gpu_addr, .size = buffer.size };
    }
    dk.dkCmdBufBindVtxBuffers(swapchain.command_buffer, 0, extents[0..].ptr, pl.vtx_buffer_count);
    if (mesh.index_count > 0) {
        dk.dkCmdBufBindIdxBuffer(swapchain.command_buffer, dk.IdxFormatUint16, mesh.index.gpu_addr);
    }
    context.mark_gpu_draw(
        swapchain.command_buffer,
        .draw_bound,
        @intCast(frame_index),
        @intCast(swapchain.image_index),
        frame_draw_calls,
        @intCast(mesh_id),
        count,
        texture_id,
        buffer.size,
        next_uniform_slot - 1,
    );
    if (mesh.index_count > 0) {
        dk.dkCmdBufDrawIndexed(swapchain.command_buffer, dk.PrimitiveTriangles, count, 1, first, 0, 0);
    } else {
        dk.dkCmdBufDraw(swapchain.command_buffer, dk.PrimitiveTriangles, count, 1, first, 0);
    }
    context.mark_gpu_draw(
        swapchain.command_buffer,
        .draw_done,
        @intCast(frame_index),
        @intCast(swapchain.image_index),
        frame_draw_calls,
        @intCast(mesh_id),
        count,
        texture_id,
        buffer.size,
        next_uniform_slot - 1,
    );

    frame_draw_calls += 1;
    frame_vertex_count += count;
}

pub fn create_texture(desc: *const Texture.UploadDesc) gfx.CreateTextureError!Texture.Handle {
    const width = desc.width;
    const height = desc.height;
    const data = desc.pixels;
    if (width == 0 or height == 0) return error.InvalidTextureSize;
    if (data.len < @as(usize, width) * @as(usize, height) * 4) return error.TextureDataTooSmall;
    collect_retired_texture_slots();

    const handle = texture_slots.add(.{}) orelse return error.OutOfTextures;
    const tex = texture_slots.get_ptr(handle) orelse return error.OutOfTextures;
    errdefer {
        destroy_texture_data(tex, false);
        _ = texture_slots.remove(handle);
    }

    create_texture_image(tex, width, height) catch |err| switch (err) {
        else => return error.GfxInitFailed,
    };
    tex.alive = true;
    upload_texture_pixels(handle, tex, data) catch return error.GfxInitFailed;
    return handle;
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const tex = texture_slots.get_ptr(handle) orelse Util.panic_invalid_handle("switch gfx", "update_texture", handle);
    if (!tex.alive) return;
    if (data.len < @as(usize, tex.width) * @as(usize, tex.height) * 4) return;
    upload_texture_pixels(handle, tex, data) catch return;
}

/// Region uploads rotate through slots, each with its own staging space,
/// command memory, and fence, so an upload only waits on the one issued
/// `region_slots` uploads earlier. Waiting on the previous upload stalled for
/// up to a frame, since its copy queues behind the frames in flight.
const region_slots = 4;
const region_staging_size: u32 = 16 * 1024;
const region_cmd_size: u32 = 4 * 1024;
const region_slot_size: u32 = region_staging_size + region_cmd_size;
var region_mem: dk.DkMemBlock = null;
var region_cmdbuf: dk.DkCmdBuf = null;
var region_fences: [region_slots]dk.DkFence = undefined;
var region_fence_pending: [region_slots]bool = @splat(false);
var region_next: u32 = 0;

fn ensure_region_ring() !void {
    if (region_mem != null) return;
    region_mem = try context.create_mem_block(region_slot_size * region_slots, dk.MemCpuUncached | dk.MemGpuCached);
    errdefer {
        dk.dkMemBlockDestroy(region_mem);
        region_mem = null;
    }
    var cmd_maker = dk.DkCmdBufMaker{
        .device = context.device,
        .userData = null,
        .cbAddMem = null,
    };
    region_cmdbuf = dk.dkCmdBufCreate(&cmd_maker);
    if (region_cmdbuf == null) return error.GfxInitFailed;
}

fn destroy_region_ring() void {
    region_fence_pending = @splat(false);
    if (region_cmdbuf) |_| dk.dkCmdBufDestroy(region_cmdbuf);
    region_cmdbuf = null;
    if (region_mem) |mem| dk.dkMemBlockDestroy(mem);
    region_mem = null;
}

/// Upload one rectangle of `data` (linear RGBA8, full texture). Queue order
/// already puts the copy after frames submitted earlier, so unlike a full
/// upload this never drains the GPU.
pub fn update_texture_region(handle: Texture.Handle, data: []align(16) u8, x: u32, y: u32, width: u32, height: u32) void {
    const tex = texture_slots.get_ptr(handle) orelse Util.panic_invalid_handle("switch gfx", "update_texture_region", handle);
    if (!tex.alive) return;
    assert(x + width <= tex.width and y + height <= tex.height);
    const bytes = width * height * 4;
    if (!initialized or bytes > region_staging_size) return update_texture(handle, data);
    ensure_region_ring() catch return update_texture(handle, data);

    const slot = region_next;
    region_next = (region_next + 1) % region_slots;
    if (region_fence_pending[slot]) {
        context.wait_fence(&region_fences[slot], "texture region slot");
        region_fence_pending[slot] = false;
    }
    const base = slot * region_slot_size;
    const cpu: [*]u8 = @ptrCast(dk.dkMemBlockGetCpuAddr(region_mem) orelse return);
    const staging = cpu + base;
    for (0..height) |row| {
        const src = ((y + row) * tex.width + x) * 4;
        @memcpy(staging[row * width * 4 ..][0 .. width * 4], data[src..][0 .. width * 4]);
    }
    _ = dk.dkMemBlockFlushCpuCache(region_mem, base, bytes);

    dk.dkCmdBufClear(region_cmdbuf);
    dk.dkCmdBufAddMemory(region_cmdbuf, region_mem, base + region_staging_size, region_cmd_size);
    dk.dkCmdBufBarrier(region_cmdbuf, dk.BarrierFull, 0);
    var copy_src = dk.DkCopyBuf{
        .addr = dk.dkMemBlockGetGpuAddr(region_mem) + base,
        .rowLength = 0,
        .imageHeight = 0,
    };
    var copy_dst = dk.DkImageRect{
        .x = x,
        .y = y,
        .z = 0,
        .width = width,
        .height = height,
        .depth = 1,
    };
    dk.dkCmdBufCopyBufferToImage(region_cmdbuf, &copy_src, &tex.view, &copy_dst, 0);
    dk.dkCmdBufBarrier(region_cmdbuf, dk.BarrierFull, dk.InvalidateImage);
    const list = dk.dkCmdBufFinishList(region_cmdbuf);
    if (list == 0) Context.panic_gpu("deko3d failed to finish texture region command list", .{});
    dk.dkQueueSubmitCommands(context.queue, list);
    region_fences[slot] = dk.emptyFence();
    dk.dkQueueSignalFence(context.queue, &region_fences[slot], false);
    context.flush_queue("texture region flush");
    region_fence_pending[slot] = true;
}

fn bind_texture(handle: Texture.Handle) void {
    if (handle.is_null()) return;
    const tex = texture_slots.get(handle) orelse Util.panic_invalid_handle("switch gfx", "bind_texture", handle);
    if (!tex.alive) return;
    current_texture = handle;
    draw_state.tex_id = @intCast(texture_slots.raw_index(handle) orelse 0);
}

pub fn destroy_texture(handle: Texture.Handle) void {
    if (handle.is_null()) return;
    const tex = texture_slots.get_ptr(handle) orelse Util.panic_invalid_handle("switch gfx", "destroy_texture", handle);
    if (!tex.alive) return;
    const texture_id: u32 = @intCast(texture_slots.raw_index(handle) orelse return);
    destroy_texture_data(tex, true);
    image_descriptors[texture_id] = fallback_image_descriptor();
    if (image_descriptor_count == texture_id + 1) recompute_image_descriptor_count();
    image_descriptors_dirty = true;
    tex.alive = false;
    retired_texture_slots.append(render_alloc, .{
        .handle = handle,
        .retire_after_completed_frames = gc.completed_frames + Swapchain.max_frames,
    }) catch {
        context.wait_idle("texture slot retirement fallback");
        _ = texture_slots.remove(handle);
    };
    if (current_texture == handle) {
        current_texture = .none;
        draw_state.tex_id = 0;
    }
}

pub fn force_texture_resident(_: Texture.Handle) void {}

fn init_pipeline(layout: vertex.VertexLayout) !PipelineData {
    const vertex_code: [:0]align(4) const u8 = &basic_vert;
    const fragment_code: [:0]align(4) const u8 = &basic_frag;

    var data = PipelineData{
        .vertex_shader = undefined,
        .fragment_shader = undefined,
        .attribs = @splat(.{ .bits = 0 }),
        .attrib_count = 0,
        .vtx_buffers = @splat(.{ .stride = 0, .divisor = 0 }),
        .vtx_buffer_count = 0,
    };

    try init_layout(&data, layout);
    try load_shader(&data.vertex_shader, vertex_code);
    try load_shader(&data.fragment_shader, fragment_code);
    return data;
}

fn collect_retired_texture_slots() void {
    var write: usize = 0;
    for (retired_texture_slots.items) |retired| {
        if (retired.retire_after_completed_frames <= gc.completed_frames) {
            if (texture_slots.get(retired.handle)) |tex| {
                if (!tex.alive) {
                    _ = texture_slots.remove(retired.handle);
                }
            }
        } else {
            retired_texture_slots.items[write] = retired;
            write += 1;
        }
    }
    retired_texture_slots.shrinkRetainingCapacity(write);
}

fn create_code_memory() !void {
    code_mem = try context.create_mem_block(code_mem_size, dk.MemCpuUncached | dk.MemGpuCached | dk.MemCode);
    code_offset = 0;
}

fn destroy_code_memory() void {
    if (code_mem) |_| {
        dk.dkMemBlockDestroy(code_mem);
        code_mem = null;
    }
    code_offset = 0;
}

fn create_uniform_memory() !void {
    uniform_mem = try context.create_mem_block(uniform_frame_size * Swapchain.max_frames, dk.MemCpuUncached | dk.MemGpuCached);
    uniform_gpu_addr = dk.dkMemBlockGetGpuAddr(uniform_mem);
}

fn destroy_uniform_memory() void {
    if (uniform_mem) |_| {
        dk.dkMemBlockDestroy(uniform_mem);
        uniform_mem = null;
    }
    uniform_gpu_addr = 0;
}

fn create_upload_command_buffer() !void {
    upload_command_mem = try context.create_mem_block(upload_cmd_mem_size, dk.MemCpuUncached | dk.MemGpuCached);
    errdefer {
        dk.dkMemBlockDestroy(upload_command_mem);
        upload_command_mem = null;
    }

    var cmd_maker = dk.DkCmdBufMaker{
        .device = context.device,
        .userData = null,
        .cbAddMem = null,
    };
    upload_command_buffer = dk.dkCmdBufCreate(&cmd_maker);
    if (upload_command_buffer == null) return error.GfxInitFailed;
}

fn destroy_upload_command_buffer() void {
    if (upload_command_buffer) |_| {
        dk.dkCmdBufDestroy(upload_command_buffer);
        upload_command_buffer = null;
    }
    if (upload_command_mem) |_| {
        dk.dkMemBlockDestroy(upload_command_mem);
        upload_command_mem = null;
    }
}

fn create_descriptor_memory() !void {
    const image_bytes = image_descriptor_frame_size * Swapchain.max_frames;
    const sampler_offset = dk.alignForward(image_bytes, dk.ImageDescriptorAlignment);
    const total_size = sampler_offset + dk.SamplerDescriptorSize;
    descriptor_mem = try context.create_mem_block(total_size, dk.MemCpuUncached | dk.MemGpuCached);
    descriptor_cpu_addr = @ptrCast(dk.dkMemBlockGetCpuAddr(descriptor_mem) orelse return error.GfxInitFailed);
    image_descriptor_base_gpu_addr = dk.dkMemBlockGetGpuAddr(descriptor_mem);
    sampler_descriptor_offset = sampler_offset;
    sampler_descriptor_gpu_addr = image_descriptor_base_gpu_addr + sampler_offset;
    image_descriptors = @splat(.{ ._storage = @splat(0) });
    image_descriptor_count = 1;
    image_descriptors_dirty = true;
    image_descriptor_table_indices = @splat(0);
}

fn destroy_descriptor_memory() void {
    if (descriptor_mem) |_| {
        dk.dkMemBlockDestroy(descriptor_mem);
        descriptor_mem = null;
    }
    descriptor_cpu_addr = null;
    image_descriptor_base_gpu_addr = 0;
    sampler_descriptor_offset = 0;
    sampler_descriptor_gpu_addr = 0;
}

fn initialize_sampler_descriptor() !void {
    var sampler = dk.defaultSampler();
    var descriptor: dk.DkSamplerDescriptor = undefined;
    dk.dkSamplerDescriptorInitialize(&descriptor, &sampler);

    const dst = descriptor_cpu_addr orelse return error.GfxInitFailed;
    @memcpy(dst[sampler_descriptor_offset..][0..@sizeOf(dk.DkSamplerDescriptor)], std.mem.asBytes(&descriptor));
    _ = dk.dkMemBlockFlushCpuCache(descriptor_mem, sampler_descriptor_offset, @sizeOf(dk.DkSamplerDescriptor));
}

fn publish_image_descriptors_for_frame(frame_index: usize) void {
    const dst = descriptor_cpu_addr orelse return;
    const byte_count = image_descriptor_count * dk.ImageDescriptorSize;
    const offset: u32 = @intCast(
        @as(dk.DkGpuAddr, @intCast(frame_index)) * image_descriptor_frame_size +
            @as(dk.DkGpuAddr, image_descriptor_table_indices[frame_index]) * image_descriptor_table_size,
    );
    var published: [max_textures]dk.DkImageDescriptor = undefined;
    const count: usize = @intCast(image_descriptor_count);
    for (published[0..count], 0..) |*descriptor, index| {
        if (is_texture_index_live(@intCast(index))) {
            descriptor.* = image_descriptors[index];
        } else {
            descriptor.* = fallback_image_descriptor();
        }
    }
    @memcpy(dst[offset..][0..byte_count], std.mem.asBytes(&published)[0..byte_count]);
    _ = dk.dkMemBlockFlushCpuCache(descriptor_mem, offset, byte_count);
    if (swapchain.recording) {
        dk.dkCmdBufBarrier(swapchain.command_buffer, dk.BarrierFull, dk.InvalidateDescriptors | dk.InvalidateL2Cache);
    }
}

fn fallback_image_descriptor() dk.DkImageDescriptor {
    if (image_descriptor_is_zero(&image_descriptors[0])) {
        return .{ ._storage = @splat(0) };
    }
    return image_descriptors[0];
}

fn is_texture_index_live(index: u32) bool {
    if (index == 0) return !image_descriptor_is_zero(&image_descriptors[0]);
    if (index >= texture_slots.slots.len) return false;
    const tex = texture_slots.slots[index] orelse return false;
    return tex.alive;
}

fn image_descriptor_is_zero(descriptor: *const dk.DkImageDescriptor) bool {
    for (descriptor._storage) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

fn resolve_texture_index(index: u32) u32 {
    if (is_texture_index_live(index)) return index;
    return 0;
}

fn bind_current_image_descriptor_set() void {
    const frame_index = swapchain.frame_index;
    const addr = image_descriptor_base_gpu_addr +
        @as(dk.DkGpuAddr, @intCast(frame_index)) * image_descriptor_frame_size +
        @as(dk.DkGpuAddr, image_descriptor_table_indices[frame_index]) * image_descriptor_table_size;
    dk.dkCmdBufBindImageDescriptorSet(swapchain.command_buffer, addr, image_descriptor_count);
}

fn ensure_image_descriptors_current() void {
    if (!image_descriptors_dirty or !swapchain.recording) return;
    const frame_index = swapchain.frame_index;
    if (image_descriptor_table_indices[frame_index] + 1 < image_descriptor_tables_per_frame) {
        image_descriptor_table_indices[frame_index] += 1;
    } else {
        Util.engine_logger.warn("Switch image descriptor table ring exhausted; reusing latest descriptor table", .{});
    }
    publish_image_descriptors_for_frame(swapchain.frame_index);
    bind_current_image_descriptor_set();
    image_descriptors_dirty = false;
}

fn create_fallback_texture() !void {
    var white align(16) = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    current_texture = try create_texture(&.{
        .width = 1,
        .height = 1,
        .pixels = white[0..],
    });
    const current_index = texture_slots.raw_index(current_texture) orelse return error.OutOfTextures;
    image_descriptors[0] = image_descriptors[current_index];
    image_descriptors_dirty = true;
    draw_state.tex_id = 0;
}

fn create_texture_image(tex: *TextureData, width: u32, height: u32) !void {
    var layout_maker = dk.DkImageLayoutMaker{
        .device = context.device,
        .type = dk.ImageType2d,
        .flags = dk.ImageUsage2dEngine,
        .format = dk.ImageRgba8Unorm,
        .msMode = 0,
        .dimensions = .{ width, height, 0 },
        .mipLevels = 1,
        .unnamed_0 = .{ .pitchStride = 0 },
    };

    var layout: dk.DkImageLayout = undefined;
    dk.dkImageLayoutInitialize(&layout, &layout_maker);
    const image_align = dk.dkImageLayoutGetAlignment(&layout);
    const image_size = dk.alignForward(@intCast(dk.dkImageLayoutGetSize(&layout)), image_align);
    tex.mem_block = try context.create_mem_block(image_size, dk.MemGpuCached | dk.MemImage);
    dk.dkImageInitialize(&tex.image, &layout, tex.mem_block, 0);
    tex.view = dk.imageView(&tex.image);
    tex.width = width;
    tex.height = height;
}

fn upload_texture_pixels(handle: Texture.Handle, tex: *TextureData, data: []const u8) !void {
    if (upload_command_buffer == null or upload_command_mem == null) return error.GfxInitFailed;
    if (initialized) context.wait_idle("texture upload dependency");

    const byte_count: u32 = @intCast(@as(usize, tex.width) * @as(usize, tex.height) * 4);
    const staging_size = dk.alignForward(byte_count, dk.ImageLinearStrideAlignment);
    const staging_mem = try context.create_mem_block(staging_size, dk.MemCpuUncached | dk.MemGpuCached);
    defer dk.dkMemBlockDestroy(staging_mem);

    const staging_cpu: [*]u8 = @ptrCast(dk.dkMemBlockGetCpuAddr(staging_mem) orelse return error.GfxInitFailed);
    @memcpy(staging_cpu[0..byte_count], data[0..byte_count]);
    _ = dk.dkMemBlockFlushCpuCache(staging_mem, 0, byte_count);

    begin_upload_commands();
    var copy_src = dk.DkCopyBuf{
        .addr = dk.dkMemBlockGetGpuAddr(staging_mem),
        .rowLength = 0,
        .imageHeight = 0,
    };
    var copy_dst = dk.DkImageRect{
        .x = 0,
        .y = 0,
        .z = 0,
        .width = tex.width,
        .height = tex.height,
        .depth = 1,
    };
    dk.dkCmdBufCopyBufferToImage(upload_command_buffer, &copy_src, &tex.view, &copy_dst, 0);
    context.mark_gpu(upload_command_buffer, .upload_copy);

    var descriptor: dk.DkImageDescriptor = undefined;
    dk.dkImageDescriptorInitialize(&descriptor, &tex.view, false, false);
    const texture_index = texture_slots.raw_index(handle) orelse return error.OutOfTextures;
    image_descriptors[texture_index] = descriptor;
    image_descriptor_count = math.max(image_descriptor_count, @as(u32, @intCast(texture_index + 1)));
    image_descriptors_dirty = true;
    dk.dkCmdBufBarrier(upload_command_buffer, dk.BarrierFull, dk.InvalidateImage);
    submit_upload_commands("texture upload");
}

fn destroy_texture_data(tex: *TextureData, deferred: bool) void {
    if (tex.mem_block) |mem| {
        if (deferred and initialized) {
            gc.defer_destroy_mem_block_after_frame_mask(swapchain.pending_frame_mask(), mem) catch {
                context.wait_idle("texture deferred destroy fallback");
                dk.dkMemBlockDestroy(mem);
            };
        } else {
            dk.dkMemBlockDestroy(mem);
        }
        tex.mem_block = null;
    }
    tex.width = 0;
    tex.height = 0;
    tex.alive = false;
}

fn begin_upload_commands() void {
    dk.dkCmdBufClear(upload_command_buffer);
    dk.dkCmdBufAddMemory(upload_command_buffer, upload_command_mem, 0, upload_cmd_mem_size);
}

fn submit_upload_commands(comptime where: []const u8) void {
    const list = dk.dkCmdBufFinishList(upload_command_buffer);
    if (list == 0) Context.panic_gpu("deko3d failed to finish upload command list at {s}", .{where});
    dk.dkQueueSubmitCommands(context.queue, list);
    context.flush_queue(where ++ " flush");
    context.assert_queue_ok(where);
    context.wait_idle(where ++ " wait");
}

var l2_invalidate_pending = false;

fn upload_mesh_buffer(buffer: *MeshBuffer, src: []const u8, in_flight: u32) !void {
    if (src.len == 0) {
        mesh_heap.free(buffer.range, in_flight);
        buffer.* = .{};
        return;
    }
    const needed: u32 = @intCast(src.len);
    if (buffer.range.mem_block == null or buffer.range.capacity < needed or in_flight != 0) {
        mesh_heap.free(buffer.range, in_flight);
        buffer.* = .{};
        buffer.range = try mesh_heap.alloc(needed);
        buffer.gpu_addr = buffer.range.gpu_addr();
    }
    const dst = buffer.range.cpu() orelse return error.GfxInitFailed;
    @memcpy(dst[0..src.len], src);
    _ = dk.dkMemBlockFlushCpuCache(buffer.range.mem_block, buffer.range.offset, needed);
    buffer.size = needed;
}

fn destroy_mesh_data(mesh: *MeshData, deferred: bool) void {
    const in_flight: u32 = if (deferred and initialized) swapchain.pending_frame_mask() else 0;
    mesh_heap.free(mesh.vertex.range, in_flight);
    mesh_heap.free(mesh.index.range, in_flight);
    mesh.* = .{};
}

fn destroy_all_meshes() void {
    for (&meshes.slots) |*slot| {
        if (slot.*) |*mesh| destroy_mesh_data(mesh, false);
        slot.* = null;
    }
    meshes.clear();
}

fn destroy_all_textures() void {
    for (&texture_slots.slots) |*slot| {
        if (slot.*) |*tex| destroy_texture_data(tex, false);
        slot.* = null;
    }
    texture_slots.clear();
    retired_texture_slots.clearRetainingCapacity();
    image_descriptors = @splat(.{ ._storage = @splat(0) });
    image_descriptor_count = 1;
    image_descriptors_dirty = true;
    current_texture = .none;
    draw_state.tex_id = 0;
}

fn recompute_image_descriptor_count() void {
    var count: u32 = 1;
    for (texture_slots.slots, 0..) |slot, index| {
        if (slot) |tex| {
            if (tex.alive) count = math.max(count, @as(u32, @intCast(index + 1)));
        }
    }
    image_descriptor_count = count;
}

fn bind_draw_uniform(texture_id: u32) bool {
    if (next_uniform_slot >= uniform_slots) return false;

    var uniform = DrawUniform{
        .model = draw_state.mat.data,
        .view = pending_state.view.data,
        .proj = pending_state.proj.data,
        .texture_index = texture_id,
        .fog_enabled = draw_state.fog_enabled,
        .fog_start = draw_state.fog_start,
        .fog_end = draw_state.fog_end,
        .fog_color = draw_state.fog_color,
        .alpha_blend_enabled = draw_state.alpha_blend_enabled,
        .uv_offset = draw_state.uv_offset,
    };

    const addr = uniform_gpu_addr +
        @as(dk.DkGpuAddr, @intCast(swapchain.frame_index)) * uniform_frame_size +
        @as(dk.DkGpuAddr, next_uniform_slot) * uniform_stride;
    dk.dkCmdBufPushConstants(swapchain.command_buffer, addr, uniform_stride, 0, @sizeOf(DrawUniform), &uniform);
    const uniform_buffers = [_]dk.DkBufExtents{.{ .addr = addr, .size = uniform_stride }};
    dk.dkCmdBufBindUniformBuffers(swapchain.command_buffer, dk.StageVertex, 0, uniform_buffers[0..].ptr, uniform_buffers.len);
    dk.dkCmdBufBindUniformBuffers(swapchain.command_buffer, dk.StageFragment, 0, uniform_buffers[0..].ptr, uniform_buffers.len);
    next_uniform_slot += 1;
    return true;
}

fn load_shader(shader: *dk.DkShader, code: []const u8) !void {
    if (code_mem == null) return error.GfxInitFailed;

    const offset = dk.alignForward(code_offset, dk.ShaderCodeAlignment);
    const end = offset + dk.alignForward(@intCast(code.len), dk.ShaderCodeAlignment);
    if (end > code_mem_size) return error.OutOfShaderMemory;

    const base: [*]u8 = @ptrCast(dk.dkMemBlockGetCpuAddr(code_mem) orelse return error.GfxInitFailed);
    @memcpy(base[offset..][0..code.len], code);

    var maker = dk.DkShaderMaker{
        .codeMem = code_mem,
        .control = null,
        .codeOffset = offset,
        .programId = 0,
    };
    dk.dkShaderInitialize(shader, &maker);
    if (!dk.dkShaderIsValid(shader)) return error.InvalidShader;
    code_offset = end;
}

fn init_layout(data: *PipelineData, layout: vertex.VertexLayout) !void {
    var max_location: u32 = 0;
    var max_binding: u32 = 0;

    for (layout.attributes) |attr| {
        if (attr.location >= max_vertex_attribs or attr.binding >= max_vertex_buffers) {
            return error.UnsupportedVertexLayout;
        }

        const loc: usize = attr.location;
        data.attribs[loc] = vtx_attrib(attr);
        max_location = math.max(max_location, attr.location + 1);
        max_binding = math.max(max_binding, attr.binding + 1);
    }

    for (data.vtx_buffers[0..max_binding]) |*buf| {
        buf.* = .{ .stride = @intCast(layout.stride), .divisor = 0 };
    }

    data.attrib_count = max_location;
    data.vtx_buffer_count = math.max(max_binding, 1);
}

fn vtx_attrib(attr: vertex.Attribute) dk.DkVtxAttribState {
    const Format = struct {
        size: u32,
        kind: u32,
    };
    const fmt: Format = switch (attr.format) {
        .f32x2 => .{ .size = dk.AttrSize2x32, .kind = dk.AttrTypeFloat },
        .f32x3 => .{ .size = dk.AttrSize3x32, .kind = dk.AttrTypeFloat },
        .unorm8x2 => .{ .size = dk.AttrSize2x8, .kind = dk.AttrTypeUnorm },
        .unorm8x4 => .{ .size = dk.AttrSize4x8, .kind = dk.AttrTypeUnorm },
        .unorm16x2 => .{ .size = dk.AttrSize2x16, .kind = dk.AttrTypeUnorm },
        .unorm16x3 => .{ .size = dk.AttrSize3x16, .kind = dk.AttrTypeUnorm },
        .snorm16x2 => .{ .size = dk.AttrSize2x16, .kind = dk.AttrTypeSnorm },
        .snorm16x3 => .{ .size = dk.AttrSize3x16, .kind = dk.AttrTypeSnorm },
    };

    return .{ .bits = (@as(u32, attr.binding) & 0x1F) |
        ((@as(u32, @intCast(attr.offset)) & 0x3FFF) << 7) |
        ((fmt.size & 0x3F) << 21) |
        ((fmt.kind & 0x7) << 27) };
}

fn bind_fixed_state() void {
    bind_rasterizer_state();
    bind_color_state();
    bind_blend_equation();
    bind_depth_state();
    const color_write = dk.DkColorWriteState{ .masks = 0xFFFF_FFFF };
    dk.dkCmdBufBindColorWriteState(swapchain.command_buffer, &color_write);
}

fn bind_rasterizer_state() void {
    const cull_mode: u32 = @intCast(if (culling_enabled) dk.FaceBack else dk.FaceNone);
    var rasterizer = dk.DkRasterizerState{ .bits = 1 |
        (@as(u32, @intCast(dk.PolygonModeFill)) << 3) |
        (@as(u32, @intCast(dk.PolygonModeFill)) << 5) |
        (cull_mode << 7) |
        (@as(u32, @intCast(dk.FrontFaceCcw)) << 9) |
        (@as(u32, @intCast(dk.ProvokingVertexLast)) << 10) };
    dk.dkCmdBufBindRasterizerState(swapchain.command_buffer, &rasterizer);
}

fn bind_color_state() void {
    const blend_enable_mask: u32 = @intFromBool(alpha_blend_enabled);
    var color = dk.DkColorState{ .bits = blend_enable_mask |
        (@as(u32, @intCast(dk.LogicOpCopy)) << 8) |
        (@as(u32, @intCast(dk.CompareAlways)) << 16) };
    dk.dkCmdBufBindColorState(swapchain.command_buffer, &color);
}

// Blend factors are constant; only the enable mask changes between passes.
fn bind_blend_equation() void {
    var blend = dk.DkBlendState{ .bits = @as(u32, @intCast(dk.BlendOpAdd)) |
        (@as(u32, @intCast(dk.BlendFactorSrcAlpha)) << 3) |
        (@as(u32, @intCast(dk.BlendFactorInvSrcAlpha)) << 9) |
        (@as(u32, @intCast(dk.BlendOpAdd)) << 15) |
        (@as(u32, @intCast(dk.BlendFactorOne)) << 18) |
        (@as(u32, @intCast(dk.BlendFactorInvSrcAlpha)) << 24) };
    dk.dkCmdBufBindBlendStates(swapchain.command_buffer, 0, @ptrCast(&blend), 1);
}

fn bind_depth_state() void {
    var depth = dk.depthStencilBits(depth_test_enabled, depth_write_enabled);
    dk.dkCmdBufBindDepthStencilState(swapchain.command_buffer, &depth);
}
