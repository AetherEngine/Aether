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
const shader_data = @import("aether_shaders");

const dk = @import("deko.zig");
const Context = @import("context.zig");
const Swapchain = @import("swapchain.zig");
const GarbageCollector = @import("garbage_collector.zig");

const CODE_MEM_SIZE = 512 * 1024;
const UPLOAD_CMD_MEM_SIZE = 64 * 1024;
const MAX_VERTEX_ATTRIBS = 32;
const MAX_VERTEX_BUFFERS = 16;
const MAX_TEXTURES = 256;
const UNIFORM_SLOTS = 64;
const UNIFORM_STRIDE: u32 = dk.alignForward(@intCast(@sizeOf(SwitchUniform)), dk.UniformBufferAlignment);
const UNIFORM_FRAME_SIZE: u32 = UNIFORM_STRIDE * UNIFORM_SLOTS;
const IMAGE_DESCRIPTOR_TABLES_PER_FRAME = 128;
const IMAGE_DESCRIPTOR_TABLE_SIZE: u32 = dk.alignForward(MAX_TEXTURES * dk.ImageDescriptorSize, dk.ImageDescriptorAlignment);
const IMAGE_DESCRIPTOR_FRAME_SIZE: u32 = IMAGE_DESCRIPTOR_TABLE_SIZE * IMAGE_DESCRIPTOR_TABLES_PER_FRAME;
const ALL_FRAME_BITS: u8 = (1 << Swapchain.MAX_FRAMES) - 1;
const DIAGNOSTIC_CLEAR_ONLY = false;

const PipelineData = struct {
    vertex_shader: dk.DkShader,
    fragment_shader: dk.DkShader,
    attribs: [MAX_VERTEX_ATTRIBS]dk.DkVtxAttribState,
    attrib_count: u32,
    vtx_buffers: [MAX_VERTEX_BUFFERS]dk.DkVtxBufferState,
    vtx_buffer_count: u32,
};

const MeshFrame = struct {
    mem_block: dk.DkMemBlock = null,
    gpu_addr: dk.DkGpuAddr = 0,
    capacity: u32 = 0,
    size: u32 = 0,
};

const MeshData = struct {
    frames: [Swapchain.MAX_FRAMES]MeshFrame = @splat(.{}),
    pending: ?[]u8 = null,
    pending_size: usize = 0,
    dirty_mask: u8 = 0,
};

const TextureData = struct {
    mem_block: dk.DkMemBlock = null,
    image: dk.DkImage = undefined,
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

const SwitchUniform = extern struct {
    model: [4][4]f32,
    view: [4][4]f32,
    proj: [4][4]f32,
    textureIndex: u32,
    fogEnabled: u32,
    fogStart: f32,
    fogEnd: f32,
    fogColor: [3]f32,
    alphaBlendEnabled: u32,
    uvOffset: [2]f32,
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
var image_descriptor_gpu_addr: dk.DkGpuAddr = 0;
var sampler_descriptor_gpu_addr: dk.DkGpuAddr = 0;
var image_descriptors: [MAX_TEXTURES]dk.DkImageDescriptor = @splat(.{ .storage = @splat(0) });
var image_descriptor_count: u32 = 1;
var image_descriptors_dirty = true;
var image_descriptor_table_indices: [Swapchain.MAX_FRAMES]u32 = @splat(0);

var meshes = Util.CircularBuffer(MeshData, 8192).init();
var texture_slots = Util.CircularBuffer(TextureData, MAX_TEXTURES).init();
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
var current_texture: Texture.Handle = 0;
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

    context.waitIdle("switch gfx deinit");
    destroy_all_meshes();
    destroy_all_textures();
    retired_texture_slots.deinit(render_alloc);
    retired_texture_slots = .empty;
    gc.collectAll();

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

pub fn start_frame() bool {
    if (!initialized) return false;
    if (!swapchain.beginFrame(&gc)) return false;
    collect_retired_texture_slots();

    next_uniform_slot = 0;
    frame_draw_calls = 0;
    frame_vertex_count = 0;

    if (DIAGNOSTIC_CLEAR_ONLY) {
        const diagnostic_clear: [4]f32 = .{ 1.0, 0.0, 1.0, 1.0 };
        swapchain.bindRenderTargetsAndClear(&diagnostic_clear);
        return true;
    }

    upload_dirty_meshes_for_frame(swapchain.frame_index);

    swapchain.bindRenderTargetsAndClear(&clear_color);
    image_descriptor_table_indices[swapchain.frame_index] = 0;
    publish_image_descriptors_for_frame(swapchain.frame_index);
    image_descriptors_dirty = false;
    bind_current_image_descriptor_set();
    dk.dkCmdBufBindSamplerDescriptorSet(swapchain.command_buffer, sampler_descriptor_gpu_addr, 1);
    bind_fixed_state();
    return true;
}

pub fn end_frame() void {
    if (!initialized) return;
    _ = swapchain.endFrame();
}

pub fn clear_depth() void {
    if (!initialized or !swapchain.recording) return;
    dk.dkCmdBufClearDepthStencil(swapchain.command_buffer, true, 1.0, 0xFF, 0);
}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
    if (initialized) swapchain.setVsync(v);
}

pub fn create_mesh() anyerror!Mesh.Handle {
    const mesh = meshes.add_element(.{}) orelse return error.OutOfMeshes;
    return @intCast(mesh);
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    var mesh = meshes.get_element(handle) orelse return;
    destroy_mesh_data(&mesh, true);
    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    var mesh = meshes.get_element(handle) orelse return;

    if (data.len > 0) {
        if (mesh.pending == null or mesh.pending.?.len < data.len) {
            if (mesh.pending) |pending| render_alloc.free(pending);
            var new_cap: usize = 256;
            while (new_cap < data.len) new_cap *= 2;
            mesh.pending = render_alloc.alloc(u8, new_cap) catch {
                mesh.pending_size = 0;
                meshes.update_element(handle, mesh);
                return;
            };
        }
        @memcpy(mesh.pending.?[0..data.len], data);
    }

    mesh.pending_size = data.len;
    mesh.dirty_mask = ALL_FRAME_BITS;
    meshes.update_element(handle, mesh);
}

pub fn draw_mesh(handle: Mesh.Handle, model: *const Mat4, count: usize) void {
    if (DIAGNOSTIC_CLEAR_ONLY) return;
    if (!initialized or !render_pipeline_initialized or !swapchain.recording) return;
    var mesh = meshes.get_element(handle) orelse return;
    const frame_index = swapchain.frame_index;
    const frame_bit: u8 = @as(u8, 1) << @intCast(frame_index);
    if ((mesh.dirty_mask & frame_bit) != 0) {
        upload_mesh_for_frame(&mesh, frame_index) catch return;
        meshes.update_element(handle, mesh);
    }

    const frame = mesh.frames[frame_index];
    if (frame.mem_block == null or frame.size == 0 or count == 0) return;

    ensure_image_descriptors_current();

    draw_state.mat = model.*;
    const pl = &render_pipeline;
    const shaders = [_]*const dk.DkShader{ &pl.vertex_shader, &pl.fragment_shader };
    dk.dkCmdBufBindShaders(swapchain.command_buffer, dk.StageGraphicsMask, shaders[0..].ptr, shaders.len);

    bind_draw_uniform();
    const texture_handle = [_]dk.DkResHandle{dk.makeTextureHandle(draw_state.tex_id, 0)};
    dk.dkCmdBufBindTextures(swapchain.command_buffer, dk.StageFragment, 1, texture_handle[0..].ptr, texture_handle.len);
    dk.dkCmdBufBindVtxAttribState(swapchain.command_buffer, pl.attribs[0..].ptr, pl.attrib_count);
    dk.dkCmdBufBindVtxBufferState(swapchain.command_buffer, pl.vtx_buffers[0..].ptr, pl.vtx_buffer_count);

    var extents: [MAX_VERTEX_BUFFERS]dk.DkBufExtents = undefined;
    for (extents[0..pl.vtx_buffer_count]) |*extent| {
        extent.* = .{ .addr = frame.gpu_addr, .size = frame.size };
    }
    dk.dkCmdBufBindVtxBuffers(swapchain.command_buffer, 0, extents[0..].ptr, pl.vtx_buffer_count);
    dk.dkCmdBufDraw(swapchain.command_buffer, dk.PrimitiveTriangles, @intCast(count), 1, 0, 0);

    frame_draw_calls += 1;
    frame_vertex_count += @intCast(count);
}

pub fn create_texture(width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle {
    if (width == 0 or height == 0) return error.InvalidTextureSize;
    if (data.len < @as(usize, width) * @as(usize, height) * 4) return error.TextureDataTooSmall;
    collect_retired_texture_slots();

    const handle_usize = texture_slots.add_element(.{}) orelse return error.OutOfTextures;
    const handle: Texture.Handle = @intCast(handle_usize);
    var tex = texture_slots.get_element(handle) orelse return error.OutOfTextures;
    errdefer {
        destroy_texture_data(&tex, false);
        _ = texture_slots.remove_element(handle);
    }

    try create_texture_image(&tex, width, height);
    tex.alive = true;
    try upload_texture_pixels(handle, &tex, data);
    texture_slots.update_element(handle, tex);
    return handle;
}

pub fn update_texture(handle: Texture.Handle, data: []align(16) u8) void {
    var tex = texture_slots.get_element(handle) orelse return;
    if (!tex.alive) return;
    if (data.len < @as(usize, tex.width) * @as(usize, tex.height) * 4) return;
    upload_texture_pixels(handle, &tex, data) catch return;
    texture_slots.update_element(handle, tex);
}

pub fn bind_texture(handle: Texture.Handle) void {
    const tex = texture_slots.get_element(handle) orelse return;
    if (!tex.alive) return;
    current_texture = handle;
    draw_state.tex_id = handle;
}

pub fn destroy_texture(handle: Texture.Handle) void {
    var tex = texture_slots.get_element(handle) orelse return;
    if (!tex.alive) return;
    destroy_texture_data(&tex, true);
    image_descriptors[handle] = .{ .storage = @splat(0) };
    if (image_descriptor_count == handle + 1) recompute_image_descriptor_count();
    image_descriptors_dirty = true;
    tex.alive = false;
    texture_slots.update_element(handle, tex);
    retired_texture_slots.append(render_alloc, .{
        .handle = handle,
        .retire_after_completed_frames = gc.completed_frames + Swapchain.MAX_FRAMES,
    }) catch {
        context.waitIdle("texture slot retirement fallback");
        _ = texture_slots.remove_element(handle);
    };
    if (current_texture == handle) {
        current_texture = 0;
        draw_state.tex_id = 0;
    }
}

pub fn force_texture_resident(_: Texture.Handle) void {}

fn init_pipeline(layout: vertex.VertexLayout) !PipelineData {
    const vertex_code: [:0]align(4) const u8 = &shader_data.basic_vert;
    const fragment_code: [:0]align(4) const u8 = &shader_data.basic_frag;

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
            if (texture_slots.get_element(retired.handle)) |tex| {
                if (!tex.alive) {
                    _ = texture_slots.remove_element(retired.handle);
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
    code_mem = try context.createMemBlock(CODE_MEM_SIZE, dk.MemCpuUncached | dk.MemGpuCached | dk.MemCode);
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
    uniform_mem = try context.createMemBlock(UNIFORM_FRAME_SIZE * Swapchain.MAX_FRAMES, dk.MemCpuUncached | dk.MemGpuCached);
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
    upload_command_mem = try context.createMemBlock(UPLOAD_CMD_MEM_SIZE, dk.MemCpuUncached | dk.MemGpuCached);
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
    descriptor_mem = try context.createMemBlock(total_size, dk.MemCpuUncached | dk.MemGpuCached);
    image_descriptor_gpu_addr = dk.dkMemBlockGetGpuAddr(descriptor_mem);
    sampler_descriptor_gpu_addr = image_descriptor_gpu_addr + sampler_offset;
    image_descriptors = @splat(.{ .storage = @splat(0) });
    image_descriptor_count = 1;
    image_descriptors_dirty = true;
    image_descriptor_table_indices = @splat(0);
}

fn destroy_descriptor_memory() void {
    if (descriptor_mem) |_| {
        dk.dkMemBlockDestroy(descriptor_mem);
        descriptor_mem = null;
    }
    image_descriptor_gpu_addr = 0;
    sampler_descriptor_gpu_addr = 0;
}

fn initialize_sampler_descriptor() !void {
    var sampler = dk.DkSampler{
        .minFilter = dk.FilterNearest,
        .magFilter = dk.FilterNearest,
        .mipFilter = dk.MipFilterNone,
        .wrapMode = .{ dk.WrapRepeat, dk.WrapRepeat, dk.WrapRepeat },
        .lodClampMin = 0.0,
        .lodClampMax = 1000.0,
        .lodBias = 0.0,
        .lodSnap = 0.0,
        .compareEnable = false,
        .compareOp = dk.CompareLess,
        .borderColor = .{
            .{ .value_ui = 0 },
            .{ .value_ui = 0 },
            .{ .value_ui = 0 },
            .{ .value_ui = 0 },
        },
        .maxAnisotropy = 1.0,
        .reductionMode = dk.SamplerReductionWeightedAverage,
    };
    var descriptor: dk.DkSamplerDescriptor = undefined;
    dk.dkSamplerDescriptorInitialize(&descriptor, &sampler);

    begin_upload_commands();
    dk.dkCmdBufPushData(upload_command_buffer, sampler_descriptor_gpu_addr, &descriptor, @sizeOf(dk.DkSamplerDescriptor));
    dk.dkCmdBufBarrier(upload_command_buffer, dk.BarrierFull, dk.InvalidateDescriptors);
    submit_upload_commands("sampler descriptor upload");
}

fn imageDescriptorGpuAddr(frame_index: usize) dk.DkGpuAddr {
    return image_descriptor_gpu_addr +
        @as(dk.DkGpuAddr, @intCast(frame_index)) * IMAGE_DESCRIPTOR_FRAME_SIZE +
        @as(dk.DkGpuAddr, image_descriptor_table_indices[frame_index]) * IMAGE_DESCRIPTOR_TABLE_SIZE;
}

fn publish_image_descriptors_for_frame(frame_index: usize) void {
    dk.dkCmdBufPushData(
        swapchain.command_buffer,
        imageDescriptorGpuAddr(frame_index),
        &image_descriptors,
        image_descriptor_count * dk.ImageDescriptorSize,
    );
    dk.dkCmdBufBarrier(swapchain.command_buffer, dk.BarrierFull, dk.InvalidateDescriptors);
}

fn bind_current_image_descriptor_set() void {
    dk.dkCmdBufBindImageDescriptorSet(swapchain.command_buffer, imageDescriptorGpuAddr(swapchain.frame_index), image_descriptor_count);
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
    current_texture = try create_texture(1, 1, &white);
    image_descriptors[0] = image_descriptors[current_texture];
    image_descriptors_dirty = true;
    draw_state.tex_id = 0;
}

fn create_texture_image(tex: *TextureData, width: u32, height: u32) !void {
    var layout_maker = dk.DkImageLayoutMaker{
        .device = context.device,
        .type = dk.ImageType2d,
        .flags = 0,
        .format = dk.ImageRgba8Unorm,
        .msMode = 0,
        .dimensions = .{ width, height, 0 },
        .mipLevels = 1,
        .pitchStride = 0,
    };

    var layout: dk.DkImageLayout = undefined;
    dk.dkImageLayoutInitialize(&layout, &layout_maker);
    const image_align = dk.dkImageLayoutGetAlignment(&layout);
    const image_size = dk.alignForward(@intCast(dk.dkImageLayoutGetSize(&layout)), image_align);
    tex.mem_block = try context.createMemBlock(image_size, dk.MemGpuCached | dk.MemImage);
    dk.dkImageInitialize(&tex.image, &layout, tex.mem_block, 0);
    tex.width = width;
    tex.height = height;
}

fn upload_texture_pixels(handle: Texture.Handle, tex: *TextureData, data: []const u8) !void {
    if (upload_command_buffer == null or upload_command_mem == null) return error.GfxInitFailed;
    if (initialized) context.waitIdle("texture upload dependency");

    const byte_count: u32 = @intCast(@as(usize, tex.width) * @as(usize, tex.height) * 4);
    const staging_size = dk.alignForward(byte_count, dk.ImageLinearStrideAlignment);
    const staging_mem = try context.createMemBlock(staging_size, dk.MemCpuUncached | dk.MemGpuCached);
    defer dk.dkMemBlockDestroy(staging_mem);

    const staging_cpu: [*]u8 = @ptrCast(dk.dkMemBlockGetCpuAddr(staging_mem) orelse return error.GfxInitFailed);
    @memcpy(staging_cpu[0..byte_count], data[0..byte_count]);
    _ = dk.dkMemBlockFlushCpuCache(staging_mem, 0, byte_count);

    begin_upload_commands();
    var view = dk.imageView(&tex.image);
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
    dk.dkCmdBufCopyBufferToImage(upload_command_buffer, &copy_src, &view, &copy_dst, 0);

    var descriptor: dk.DkImageDescriptor = undefined;
    dk.dkImageDescriptorInitialize(&descriptor, &view, false, false);
    image_descriptors[handle] = descriptor;
    image_descriptor_count = @max(image_descriptor_count, @as(u32, @intCast(handle + 1)));
    image_descriptors_dirty = true;
    dk.dkCmdBufBarrier(upload_command_buffer, dk.BarrierFull, dk.InvalidateImage);
    submit_upload_commands("texture upload");
}

fn destroy_texture_data(tex: *TextureData, deferred: bool) void {
    if (tex.mem_block) |mem| {
        if (deferred and initialized) {
            gc.deferDestroyMemBlockAfterFrameMask(swapchain.pendingFrameMask(), mem) catch {
                context.waitIdle("texture deferred destroy fallback");
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
    dk.dkQueueSubmitCommands(context.queue, list);
    context.assertQueueOk(where);
    context.waitIdle(where ++ " wait");
}

fn upload_dirty_meshes_for_frame(frame_index: usize) void {
    for (&meshes.buffer) |*slot| {
        if (slot.*) |*mesh| {
            const bit: u8 = @as(u8, 1) << @intCast(frame_index);
            if ((mesh.dirty_mask & bit) == 0) continue;
            upload_mesh_for_frame(mesh, frame_index) catch continue;
        }
    }
}

fn upload_mesh_for_frame(mesh: *MeshData, frame_index: usize) !void {
    const bit: u8 = @as(u8, 1) << @intCast(frame_index);
    var frame = &mesh.frames[frame_index];

    if (mesh.pending_size == 0) {
        frame.size = 0;
        mesh.dirty_mask &= ~bit;
        return;
    }

    const needed: u32 = @intCast(mesh.pending_size);
    if (frame.mem_block == null or frame.capacity < needed) {
        if (frame.mem_block) |mem| {
            gc.deferDestroyMemBlockAfterFrameMask(swapchain.pendingFrameMask(), mem) catch {
                context.waitIdle("mesh deferred destroy fallback");
                dk.dkMemBlockDestroy(mem);
            };
        }
        var new_cap: u32 = 256;
        while (new_cap < needed) new_cap *= 2;
        frame.mem_block = try context.createMemBlock(new_cap, dk.MemCpuUncached | dk.MemGpuCached);
        frame.capacity = dk.dkMemBlockGetSize(frame.mem_block);
        frame.gpu_addr = dk.dkMemBlockGetGpuAddr(frame.mem_block);
    }

    const dst: [*]u8 = @ptrCast(dk.dkMemBlockGetCpuAddr(frame.mem_block) orelse return error.GfxInitFailed);
    @memcpy(dst[0..mesh.pending_size], mesh.pending.?[0..mesh.pending_size]);
    _ = dk.dkMemBlockFlushCpuCache(frame.mem_block, 0, needed);
    frame.size = needed;
    mesh.dirty_mask &= ~bit;
}

fn destroy_mesh_data(mesh: *MeshData, deferred: bool) void {
    if (mesh.pending) |pending| {
        render_alloc.free(pending);
        mesh.pending = null;
    }
    for (&mesh.frames) |*frame| {
        if (frame.mem_block) |mem| {
            if (deferred and initialized) {
                gc.deferDestroyMemBlockAfterFrameMask(swapchain.pendingFrameMask(), mem) catch {
                    context.waitIdle("mesh deferred destroy fallback");
                    dk.dkMemBlockDestroy(mem);
                };
            } else {
                dk.dkMemBlockDestroy(mem);
            }
        }
        frame.* = .{};
    }
    mesh.pending_size = 0;
    mesh.dirty_mask = 0;
}

fn destroy_all_meshes() void {
    for (&meshes.buffer) |*slot| {
        if (slot.*) |*mesh| destroy_mesh_data(mesh, false);
        slot.* = null;
    }
    meshes.clear();
}

fn destroy_all_textures() void {
    for (&texture_slots.buffer) |*slot| {
        if (slot.*) |*tex| destroy_texture_data(tex, false);
        slot.* = null;
    }
    texture_slots.clear();
    retired_texture_slots.clearRetainingCapacity();
    image_descriptors = @splat(.{ .storage = @splat(0) });
    image_descriptor_count = 1;
    image_descriptors_dirty = true;
    current_texture = 0;
    draw_state.tex_id = 0;
}

fn recompute_image_descriptor_count() void {
    var count: u32 = 1;
    for (texture_slots.buffer, 0..) |slot, index| {
        if (slot) |tex| {
            if (tex.alive) count = @max(count, @as(u32, @intCast(index + 1)));
        }
    }
    image_descriptor_count = count;
}

fn bind_draw_uniform() void {
    if (next_uniform_slot >= UNIFORM_SLOTS) {
        Util.engine_logger.warn("Switch uniform ring exhausted ({d} slots/frame); reusing last slot", .{UNIFORM_SLOTS});
        next_uniform_slot = UNIFORM_SLOTS - 1;
    }

    var uniform = SwitchUniform{
        .model = draw_state.mat.data,
        .view = pending_state.view.data,
        .proj = pending_state.proj.data,
        .textureIndex = draw_state.tex_id,
        .fogEnabled = draw_state.fog_enabled,
        .fogStart = draw_state.fog_start,
        .fogEnd = draw_state.fog_end,
        .fogColor = draw_state.fog_color,
        .alphaBlendEnabled = draw_state.alpha_blend_enabled,
        .uvOffset = draw_state.uv_offset,
    };

    const addr = uniform_gpu_addr +
        @as(dk.DkGpuAddr, @intCast(swapchain.frame_index)) * UNIFORM_FRAME_SIZE +
        @as(dk.DkGpuAddr, next_uniform_slot) * UNIFORM_STRIDE;
    dk.dkCmdBufPushConstants(swapchain.command_buffer, addr, UNIFORM_STRIDE, 0, @sizeOf(SwitchUniform), &uniform);
    const uniform_buffers = [_]dk.DkBufExtents{.{ .addr = addr, .size = UNIFORM_STRIDE }};
    dk.dkCmdBufBindUniformBuffers(swapchain.command_buffer, dk.StageVertex, 0, uniform_buffers[0..].ptr, uniform_buffers.len);
    dk.dkCmdBufBindUniformBuffers(swapchain.command_buffer, dk.StageFragment, 0, uniform_buffers[0..].ptr, uniform_buffers.len);
    next_uniform_slot += 1;
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
        data.attribs[loc] = vtxAttrib(attr);
        max_location = @max(max_location, attr.location + 1);
        max_binding = @max(max_binding, attr.binding + 1);
    }

    for (data.vtx_buffers[0..max_binding]) |*buf| {
        buf.* = .{ .stride = @intCast(layout.stride), .divisor = 0 };
    }

    data.attrib_count = max_location;
    data.vtx_buffer_count = @max(max_binding, 1);
}

fn vtxAttrib(attr: vertex.Attribute) dk.DkVtxAttribState {
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
    var rasterizer = rasterizerState();
    dk.dkCmdBufBindRasterizerState(swapchain.command_buffer, &rasterizer);
}

fn bind_color_state() void {
    var color = colorState();
    var blend = blendState();
    dk.dkCmdBufBindColorState(swapchain.command_buffer, &color);
    dk.dkCmdBufBindBlendStates(swapchain.command_buffer, 0, @ptrCast(&blend), 1);
}

fn bind_depth_state() void {
    var depth = dk.depthStencilBits(depth_write_enabled);
    dk.dkCmdBufBindDepthStencilState(swapchain.command_buffer, &depth);
}

fn rasterizerState() dk.DkRasterizerState {
    const cull_mode: u32 = if (culling_enabled) dk.FaceBack else dk.FaceNone;
    return .{ .bits = 1 |
        (dk.PolygonModeFill << 3) |
        (dk.PolygonModeFill << 5) |
        (cull_mode << 7) |
        (dk.FrontFaceCcw << 9) |
        (dk.ProvokingVertexLast << 10) };
}

fn colorState() dk.DkColorState {
    const blend_enable_mask: u32 = @intFromBool(alpha_blend_enabled);
    return .{ .bits = blend_enable_mask |
        (dk.LogicOpCopy << 8) |
        (dk.CompareAlways << 16) };
}

fn blendState() dk.DkBlendState {
    return .{ .bits = dk.BlendOpAdd |
        (dk.BlendFactorSrcAlpha << 3) |
        (dk.BlendFactorInvSrcAlpha << 9) |
        (dk.BlendOpAdd << 15) |
        (dk.BlendFactorOne << 18) |
        (dk.BlendFactorInvSrcAlpha << 24) };
}
