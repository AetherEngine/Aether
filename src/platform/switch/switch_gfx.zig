//! Nintendo Switch deko3d backend.
//!
//! The shape intentionally tracks the desktop Vulkan backend: context owns the
//! device/queue, swapchain owns frame/depth/command resources, and this file
//! owns renderer state plus backend resource records.

const std = @import("std");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const vertex = Rendering.vertex;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const gfx = @import("../gfx.zig");
const basic_vert align(@alignOf(u32)) = @embedFile("aether_basic_vert").*;
const basic_frag align(@alignOf(u32)) = @embedFile("aether_basic_frag").*;

const dk = @import("deko.zig");
const Context = @import("context.zig");
const Swapchain = @import("swapchain.zig");
const GarbageCollector = @import("garbage_collector.zig");

pub const mesh_source_mode = Mesh.SourceMode.uploaded_copy;

const CODE_MEM_SIZE = 512 * 1024;
const UPLOAD_CMD_MEM_SIZE = 64 * 1024;
const MAX_VERTEX_ATTRIBS = 32;
const MAX_VERTEX_BUFFERS = 16;
const MAX_TEXTURES = 256;
const UNIFORM_SLOTS = 4096;
const RETAIN_PENDING_UPLOAD_LIMIT = 16 * 1024;
const UNIFORM_STRIDE: u32 = dk.alignForward(@intCast(@sizeOf(DrawUniform)), dk.UniformBufferAlignment);
const UNIFORM_FRAME_SIZE: u32 = UNIFORM_STRIDE * UNIFORM_SLOTS;
const IMAGE_DESCRIPTOR_TABLES_PER_FRAME = 128;
const IMAGE_DESCRIPTOR_TABLE_SIZE: u32 = dk.alignForward(MAX_TEXTURES * dk.ImageDescriptorSize, dk.ImageDescriptorAlignment);
const IMAGE_DESCRIPTOR_FRAME_SIZE: u32 = IMAGE_DESCRIPTOR_TABLE_SIZE * IMAGE_DESCRIPTOR_TABLES_PER_FRAME;

const PipelineData = struct {
    vertex_shader: dk.DkShader,
    fragment_shader: dk.DkShader,
    attribs: [MAX_VERTEX_ATTRIBS]dk.DkVtxAttribState,
    attrib_count: u32,
    vtx_buffers: [MAX_VERTEX_BUFFERS]dk.DkVtxBufferState,
    vtx_buffer_count: u32,
};

const MeshBuffer = struct {
    mem_block: dk.DkMemBlock = null,
    gpu_addr: dk.DkGpuAddr = 0,
    capacity: u32 = 0,
    size: u32 = 0,
};

const MeshData = struct {
    vertex: MeshUpload = .{},
    index: MeshUpload = .{},
    vertex_count: usize = 0,
    index_count: usize = 0,
    dirty: bool = false,
};

const MeshUpload = struct {
    buffer: MeshBuffer = .{},
    pending: ?[]u8 = null,
    pending_size: usize = 0,
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
var image_descriptors: [MAX_TEXTURES]dk.DkImageDescriptor = @splat(.{ ._storage = @splat(0) });
var image_descriptor_count: u32 = 1;
var image_descriptors_dirty = true;
var image_descriptor_table_indices: [Swapchain.MAX_FRAMES]u32 = @splat(0);

var meshes = Util.ResourceTable(MeshData, 8192, Mesh.Handle).init();
var texture_slots = Util.ResourceTable(TextureData, MAX_TEXTURES, Texture.Handle).init();
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

pub fn init() anyerror!void {
    _ = render_io;
    context = try Context.init(render_alloc);
    context.activate();
    errdefer context.deinit();

    swapchain = try Swapchain.init(&context, gfx.sync);
    errdefer swapchain.deinit();

    gc = GarbageCollector.init(render_alloc, &context);
    errdefer gc.deinit();

    try create_code_memory();
    errdefer destroy_code_memory();

    try create_uniform_memory();
    errdefer destroy_uniform_memory();

    try create_upload_command_buffer();
    errdefer destroy_upload_command_buffer();

    try create_descriptor_memory();
    errdefer destroy_descriptor_memory();

    try initialize_sampler_descriptor();
    render_pipeline = try init_pipeline(vertex.Layout);
    render_pipeline_initialized = true;

    try create_fallback_texture();
    errdefer destroy_all_textures();

    initialized = true;
    set_vsync(vsync_enabled);
}

pub fn deinit() void {
    if (!initialized) return;

    context.wait_idle("switch gfx deinit");
    destroy_all_meshes();
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

pub fn set_alpha_blend(enabled: bool) void {
    draw_state.alpha_blend_enabled = @intFromBool(enabled);
    if (enabled == alpha_blend_enabled) return;
    alpha_blend_enabled = enabled;
    if (initialized and swapchain.recording) bind_color_state();
}

pub fn set_depth_write(enabled: bool) void {
    if (enabled == depth_write_enabled) return;
    depth_write_enabled = enabled;
    if (initialized and swapchain.recording) bind_depth_state();
}

pub fn set_fog(enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    draw_state.fog_enabled = @intFromBool(enabled);
    draw_state.fog_start = start;
    draw_state.fog_end = end;
    draw_state.fog_color = .{ r, g, b };
}

pub fn set_clip_planes(_: bool) void {}

pub fn set_culling(enabled: bool) void {
    if (enabled == culling_enabled) return;
    culling_enabled = enabled;
    if (initialized and swapchain.recording) bind_rasterizer_state();
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
    unreachable;
}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
    if (initialized) swapchain.set_vsync(v);
}

pub fn create_mesh(_: *const Mesh.Desc) anyerror!Mesh.Handle {
    return meshes.add(.{}) orelse return error.OutOfMeshes;
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    const mesh = meshes.get_ptr(handle) orelse return;
    destroy_mesh_data(mesh, true);
    _ = meshes.remove(handle);
}

pub fn update_mesh(handle: Mesh.Handle, desc: *const Mesh.UpdateDesc) void {
    const mesh = meshes.get_ptr(handle) orelse return;
    const data = desc.vertices;
    const indices = desc.indices;

    update_mesh_upload(&mesh.vertex, data);
    update_mesh_upload(&mesh.index, std.mem.sliceAsBytes(indices));
    mesh.vertex_count = data.len / vertex.Layout.stride;
    mesh.index_count = indices.len;
    mesh.dirty = true;
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4) void {
    if (!initialized or !render_pipeline_initialized or !swapchain.recording) return;
    const mesh = meshes.get_ptr(handle) orelse return;
    const mesh_id = handle.raw_index();
    const frame_index = swapchain.frame_index;
    if (mesh.dirty) {
        if (upload_mesh(mesh, frame_index) catch return) {
            dk.dkCmdBufBarrier(swapchain.command_buffer, dk.BarrierFull, dk.InvalidateL2Cache);
        }
    }

    const buffer = mesh.vertex.buffer;
    if (buffer.mem_block == null or buffer.size == 0 or mesh.vertex_count == 0) return;
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
    if (mesh.index_count > 0 and mesh.index.buffer.size < mesh.index_count * @sizeOf(Mesh.Index)) return;
    const draw_count = if (mesh.index_count > 0) mesh.index_count else mesh.vertex_count;

    ensure_image_descriptors_current();
    const texture_id = resolve_texture_index(draw_state.tex_id);

    context.mark_gpu_draw(
        swapchain.command_buffer,
        .draw_begin,
        @intCast(frame_index),
        @intCast(swapchain.image_index),
        frame_draw_calls,
        @intCast(mesh_id),
        @intCast(draw_count),
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

    var extents: [MAX_VERTEX_BUFFERS]dk.DkBufExtents = undefined;
    for (extents[0..pl.vtx_buffer_count]) |*extent| {
        extent.* = .{ .addr = buffer.gpu_addr, .size = buffer.size };
    }
    dk.dkCmdBufBindVtxBuffers(swapchain.command_buffer, 0, extents[0..].ptr, pl.vtx_buffer_count);
    if (mesh.index_count > 0) {
        dk.dkCmdBufBindIdxBuffer(swapchain.command_buffer, dk.IdxFormatUint16, mesh.index.buffer.gpu_addr);
    }
    context.mark_gpu_draw(
        swapchain.command_buffer,
        .draw_bound,
        @intCast(frame_index),
        @intCast(swapchain.image_index),
        frame_draw_calls,
        @intCast(mesh_id),
        @intCast(draw_count),
        texture_id,
        buffer.size,
        next_uniform_slot - 1,
    );
    if (mesh.index_count > 0) {
        dk.dkCmdBufDrawIndexed(swapchain.command_buffer, dk.PrimitiveTriangles, @intCast(mesh.index_count), 1, 0, 0, 0);
    } else {
        dk.dkCmdBufDraw(swapchain.command_buffer, dk.PrimitiveTriangles, @intCast(mesh.vertex_count), 1, 0, 0);
    }
    context.mark_gpu_draw(
        swapchain.command_buffer,
        .draw_done,
        @intCast(frame_index),
        @intCast(swapchain.image_index),
        frame_draw_calls,
        @intCast(mesh_id),
        @intCast(draw_count),
        texture_id,
        buffer.size,
        next_uniform_slot - 1,
    );

    frame_draw_calls += 1;
    frame_vertex_count += @intCast(draw_count);
}

pub fn create_texture(desc: *const Texture.UploadDesc) anyerror!Texture.Handle {
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

    try create_texture_image(tex, width, height);
    tex.alive = true;
    try upload_texture_pixels(handle, tex, data);
    return handle;
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    const tex = texture_slots.get_ptr(handle) orelse return;
    if (!tex.alive) return;
    if (data.len < @as(usize, tex.width) * @as(usize, tex.height) * 4) return;
    upload_texture_pixels(handle, tex, data) catch return;
}

pub fn bind_texture(handle: Texture.Handle) void {
    const tex = texture_slots.get(handle) orelse return;
    if (!tex.alive) return;
    current_texture = handle;
    draw_state.tex_id = @intCast(texture_slots.raw_index(handle) orelse 0);
}

pub fn destroy_texture(handle: Texture.Handle) void {
    const tex = texture_slots.get_ptr(handle) orelse return;
    if (!tex.alive) return;
    const texture_id: u32 = @intCast(texture_slots.raw_index(handle) orelse return);
    destroy_texture_data(tex, true);
    image_descriptors[texture_id] = fallback_image_descriptor();
    if (image_descriptor_count == texture_id + 1) recompute_image_descriptor_count();
    image_descriptors_dirty = true;
    tex.alive = false;
    retired_texture_slots.append(render_alloc, .{
        .handle = handle,
        .retire_after_completed_frames = gc.completed_frames + Swapchain.MAX_FRAMES,
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
    code_mem = try context.create_mem_block(CODE_MEM_SIZE, dk.MemCpuUncached | dk.MemGpuCached | dk.MemCode);
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
    uniform_mem = try context.create_mem_block(UNIFORM_FRAME_SIZE * Swapchain.MAX_FRAMES, dk.MemCpuUncached | dk.MemGpuCached);
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
    upload_command_mem = try context.create_mem_block(UPLOAD_CMD_MEM_SIZE, dk.MemCpuUncached | dk.MemGpuCached);
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
    const image_bytes = IMAGE_DESCRIPTOR_FRAME_SIZE * Swapchain.MAX_FRAMES;
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
        @as(dk.DkGpuAddr, @intCast(frame_index)) * IMAGE_DESCRIPTOR_FRAME_SIZE +
            @as(dk.DkGpuAddr, image_descriptor_table_indices[frame_index]) * IMAGE_DESCRIPTOR_TABLE_SIZE,
    );
    var published: [MAX_TEXTURES]dk.DkImageDescriptor = undefined;
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
        @as(dk.DkGpuAddr, @intCast(frame_index)) * IMAGE_DESCRIPTOR_FRAME_SIZE +
        @as(dk.DkGpuAddr, image_descriptor_table_indices[frame_index]) * IMAGE_DESCRIPTOR_TABLE_SIZE;
    dk.dkCmdBufBindImageDescriptorSet(swapchain.command_buffer, addr, image_descriptor_count);
}

fn ensure_image_descriptors_current() void {
    if (!image_descriptors_dirty or !swapchain.recording) return;
    const frame_index = swapchain.frame_index;
    if (image_descriptor_table_indices[frame_index] + 1 < IMAGE_DESCRIPTOR_TABLES_PER_FRAME) {
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
    image_descriptors[handle] = descriptor;
    image_descriptor_count = @max(image_descriptor_count, @as(u32, @intCast(handle + 1)));
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
    dk.dkCmdBufAddMemory(upload_command_buffer, upload_command_mem, 0, UPLOAD_CMD_MEM_SIZE);
}

fn submit_upload_commands(comptime where: []const u8) void {
    const list = dk.dkCmdBufFinishList(upload_command_buffer);
    if (list == 0) Context.panic_gpu("deko3d failed to finish upload command list at {s}", .{where});
    dk.dkQueueSubmitCommands(context.queue, list);
    context.flush_queue(where ++ " flush");
    context.assert_queue_ok(where);
    context.wait_idle(where ++ " wait");
}

fn update_mesh_upload(upload: *MeshUpload, data: []const u8) void {
    if (data.len > 0) {
        if (upload.pending == null or upload.pending.?.len < data.len) {
            if (upload.pending) |pending| render_alloc.free(pending);
            var new_cap: usize = 256;
            while (new_cap < data.len) new_cap *= 2;
            upload.pending = render_alloc.alloc(u8, new_cap) catch {
                upload.pending_size = 0;
                return;
            };
        }
        @memcpy(upload.pending.?[0..data.len], data);
    }

    upload.pending_size = data.len;
}

fn upload_mesh(mesh: *MeshData, frame_index: usize) !bool {
    const had_vertex_data = mesh.vertex.pending_size > 0;
    const vertex_updated = try upload_mesh_part(&mesh.vertex, frame_index);
    const index_updated = try upload_mesh_part(&mesh.index, frame_index);
    if (!had_vertex_data) {
        mesh.vertex.buffer.size = 0;
        mesh.dirty = false;
        return false;
    }
    mesh.dirty = false;
    return vertex_updated or index_updated;
}

fn upload_mesh_part(upload: *MeshUpload, frame_index: usize) !bool {
    if (upload.pending_size == 0) {
        upload.buffer.size = 0;
        return false;
    }

    const needed: u32 = @intCast(upload.pending_size);
    const current_frame_bit_u32: u32 = @as(u32, 1) << @intCast(frame_index);
    const submitted_frame_mask = swapchain.pending_frame_mask() & ~current_frame_bit_u32;
    var target = &upload.buffer;

    if (target.mem_block == null or target.capacity < needed) {
        if (target.mem_block) |mem| {
            gc.defer_destroy_mem_block_after_frame_mask(submitted_frame_mask, mem) catch {
                context.wait_idle("mesh deferred destroy fallback");
                dk.dkMemBlockDestroy(mem);
            };
        }
        target.* = try create_mesh_buffer(needed);
    } else if (submitted_frame_mask != 0) {
        const old = target.*;
        target.* = try create_mesh_buffer(needed);
        gc.defer_destroy_mem_block_after_frame_mask(submitted_frame_mask, old.mem_block) catch {
            context.wait_idle("mesh deferred destroy fallback");
            dk.dkMemBlockDestroy(old.mem_block);
        };
    }

    const dst: [*]u8 = @ptrCast(dk.dkMemBlockGetCpuAddr(target.mem_block) orelse return error.GfxInitFailed);
    @memcpy(dst[0..upload.pending_size], upload.pending.?[0..upload.pending_size]);
    _ = dk.dkMemBlockFlushCpuCache(target.mem_block, 0, needed);
    target.size = needed;
    if (upload.pending) |pending| {
        if (pending.len > RETAIN_PENDING_UPLOAD_LIMIT) {
            render_alloc.free(pending);
            upload.pending = null;
            upload.pending_size = 0;
        }
    }
    return true;
}

fn create_mesh_buffer(needed: u32) !MeshBuffer {
    var new_cap: u32 = 256;
    while (new_cap < needed) new_cap *= 2;
    const mem = try context.create_mem_block(new_cap, dk.MemCpuUncached | dk.MemGpuCached);
    return .{
        .mem_block = mem,
        .capacity = dk.dkMemBlockGetSize(mem),
        .gpu_addr = dk.dkMemBlockGetGpuAddr(mem),
        .size = 0,
    };
}

fn destroy_mesh_data(mesh: *MeshData, deferred: bool) void {
    destroy_mesh_upload(&mesh.vertex, deferred);
    destroy_mesh_upload(&mesh.index, deferred);
    mesh.vertex_count = 0;
    mesh.index_count = 0;
    mesh.dirty = false;
}

fn destroy_mesh_upload(upload: *MeshUpload, deferred: bool) void {
    if (upload.pending) |pending| {
        render_alloc.free(pending);
        upload.pending = null;
    }
    destroy_mesh_buffer(&upload.buffer, deferred);
    upload.pending_size = 0;
}

fn destroy_mesh_buffer(buffer: *MeshBuffer, deferred: bool) void {
    if (buffer.mem_block) |mem| {
        if (deferred and initialized) {
            gc.defer_destroy_mem_block_after_frame_mask(swapchain.pending_frame_mask(), mem) catch {
                context.wait_idle("mesh deferred destroy fallback");
                dk.dkMemBlockDestroy(mem);
            };
        } else {
            dk.dkMemBlockDestroy(mem);
        }
    }
    buffer.* = .{};
}

fn destroy_all_meshes() void {
    for (&meshes.buffer) |*slot| {
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
            if (tex.alive) count = @max(count, @as(u32, @intCast(index + 1)));
        }
    }
    image_descriptor_count = count;
}

fn bind_draw_uniform(texture_id: u32) bool {
    if (next_uniform_slot >= UNIFORM_SLOTS) return false;

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
        @as(dk.DkGpuAddr, @intCast(swapchain.frame_index)) * UNIFORM_FRAME_SIZE +
        @as(dk.DkGpuAddr, next_uniform_slot) * UNIFORM_STRIDE;
    dk.dkCmdBufPushConstants(swapchain.command_buffer, addr, UNIFORM_STRIDE, 0, @sizeOf(DrawUniform), &uniform);
    const uniform_buffers = [_]dk.DkBufExtents{.{ .addr = addr, .size = UNIFORM_STRIDE }};
    dk.dkCmdBufBindUniformBuffers(swapchain.command_buffer, dk.StageVertex, 0, uniform_buffers[0..].ptr, uniform_buffers.len);
    dk.dkCmdBufBindUniformBuffers(swapchain.command_buffer, dk.StageFragment, 0, uniform_buffers[0..].ptr, uniform_buffers.len);
    next_uniform_slot += 1;
    return true;
}

fn load_shader(shader: *dk.DkShader, code: []const u8) !void {
    if (code_mem == null) return error.GfxInitFailed;

    const offset = dk.alignForward(code_offset, dk.ShaderCodeAlignment);
    const end = offset + dk.alignForward(@intCast(code.len), dk.ShaderCodeAlignment);
    if (end > CODE_MEM_SIZE) return error.OutOfShaderMemory;

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
        if (attr.location >= MAX_VERTEX_ATTRIBS or attr.binding >= MAX_VERTEX_BUFFERS) {
            return error.UnsupportedVertexLayout;
        }

        const loc: usize = attr.location;
        data.attribs[loc] = vtx_attrib(attr);
        max_location = @max(max_location, attr.location + 1);
        max_binding = @max(max_binding, attr.binding + 1);
    }

    for (data.vtx_buffers[0..max_binding]) |*buf| {
        buf.* = .{ .stride = @intCast(layout.stride), .divisor = 0 };
    }

    data.attrib_count = max_location;
    data.vtx_buffer_count = @max(max_binding, 1);
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
    var blend = dk.DkBlendState{ .bits = @as(u32, @intCast(dk.BlendOpAdd)) |
        (@as(u32, @intCast(dk.BlendFactorSrcAlpha)) << 3) |
        (@as(u32, @intCast(dk.BlendFactorInvSrcAlpha)) << 9) |
        (@as(u32, @intCast(dk.BlendOpAdd)) << 15) |
        (@as(u32, @intCast(dk.BlendFactorOne)) << 18) |
        (@as(u32, @intCast(dk.BlendFactorInvSrcAlpha)) << 24) };
    dk.dkCmdBufBindColorState(swapchain.command_buffer, &color);
    dk.dkCmdBufBindBlendStates(swapchain.command_buffer, 0, @ptrCast(&blend), 1);
}

fn bind_depth_state() void {
    var depth = dk.depthStencilBits(depth_write_enabled);
    dk.dkCmdBufBindDepthStencilState(swapchain.command_buffer, &depth);
}
