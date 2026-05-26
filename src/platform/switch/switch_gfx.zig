//! Minimal Nintendo Switch deko3d backend.
//!
//! This is the first bring-up milestone: render Aether's current colored
//! demo mesh through deko3d and present it. Textures, matrices, and richer
//! render state are intentionally left as no-ops until the full backend pass.

const std = @import("std");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const gfx = @import("../gfx.zig");

const DkDevice_T = opaque {};
const DkMemBlock_T = opaque {};
const DkCmdBuf_T = opaque {};
const DkQueue_T = opaque {};
const DkSwapchain_T = opaque {};

const DkDevice = ?*DkDevice_T;
const DkMemBlock = ?*DkMemBlock_T;
const DkCmdBuf = ?*DkCmdBuf_T;
const DkQueue = ?*DkQueue_T;
const DkSwapchain = ?*DkSwapchain_T;
const DkGpuAddr = u64;
const DkCmdList = usize;

const DkDeviceMaker = extern struct {
    userData: ?*anyopaque,
    cbDebug: ?*const anyopaque,
    cbAlloc: ?*const anyopaque,
    cbFree: ?*const anyopaque,
    flags: u32,
};

const DkMemBlockMaker = extern struct {
    device: DkDevice,
    size: u32,
    flags: u32,
    storage: ?*anyopaque,
};

const DkCmdBufMaker = extern struct {
    device: DkDevice,
    userData: ?*anyopaque,
    cbAddMem: ?*const anyopaque,
};

const DkQueueMaker = extern struct {
    device: DkDevice,
    flags: u32,
    commandMemorySize: u32,
    flushThreshold: u32,
    perWarpScratchMemorySize: u32,
    maxConcurrentComputeJobs: u32,
};

const DkShaderMaker = extern struct {
    codeMem: DkMemBlock,
    control: ?*const anyopaque,
    codeOffset: u32,
    programId: u32,
};

const DkImageLayoutMaker = extern struct {
    device: DkDevice,
    type: u32,
    flags: u32,
    format: u32,
    msMode: u32,
    dimensions: [3]u32,
    mipLevels: u32,
    pitchStride: u32,
};

const DkSwapchainMaker = extern struct {
    device: DkDevice,
    nativeWindow: ?*anyopaque,
    pImages: [*]const *const DkImage,
    numImages: u32,
};

const DkShader = extern struct {
    storage: [16]u64,
};

const DkImageLayout = extern struct {
    storage: [16]u64,
};

const DkImage = extern struct {
    storage: [16]u64,
};

const DkImageView = extern struct {
    pImage: *const DkImage,
    type: u32,
    format: u32,
    swizzle: [4]u32,
    dsSource: u32,
    layerOffset: u16,
    layerCount: u16,
    mipLevelOffset: u8,
    mipLevelCount: u8,
};

const DkViewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    near: f32,
    far: f32,
};

const DkScissor = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

const DkRasterizerState = extern struct {
    bits: u32,
};

const DkColorState = extern struct {
    bits: u32,
};

const DkColorWriteState = extern struct {
    masks: u32,
};

const DkDepthStencilState = extern struct {
    bits0: u32,
    bits1: u32,
};

const DkVtxAttribState = extern struct {
    bits: u32,
};

const DkVtxBufferState = extern struct {
    stride: u32,
    divisor: u32,
};

const DkBufExtents = extern struct {
    addr: DkGpuAddr,
    size: u32,
};

extern fn nwindowGetDefault() ?*anyopaque;

extern fn dkDeviceCreate(maker: *const DkDeviceMaker) DkDevice;
extern fn dkDeviceDestroy(obj: DkDevice) void;

extern fn dkMemBlockCreate(maker: *const DkMemBlockMaker) DkMemBlock;
extern fn dkMemBlockDestroy(obj: DkMemBlock) void;
extern fn dkMemBlockGetCpuAddr(obj: DkMemBlock) ?*anyopaque;
extern fn dkMemBlockGetGpuAddr(obj: DkMemBlock) DkGpuAddr;
extern fn dkMemBlockGetSize(obj: DkMemBlock) u32;
extern fn dkMemBlockFlushCpuCache(obj: DkMemBlock, offset: u32, size: u32) u32;

extern fn dkCmdBufCreate(maker: *const DkCmdBufMaker) DkCmdBuf;
extern fn dkCmdBufDestroy(obj: DkCmdBuf) void;
extern fn dkCmdBufAddMemory(obj: DkCmdBuf, mem: DkMemBlock, offset: u32, size: u32) void;
extern fn dkCmdBufFinishList(obj: DkCmdBuf) DkCmdList;
extern fn dkCmdBufClear(obj: DkCmdBuf) void;
extern fn dkCmdBufBindShaders(obj: DkCmdBuf, stageMask: u32, shaders: [*]const *const DkShader, numShaders: u32) void;
extern fn dkCmdBufBindRenderTargets(obj: DkCmdBuf, colorTargets: [*]const *const DkImageView, numColorTargets: u32, depthTarget: ?*const DkImageView) void;
extern fn dkCmdBufBindRasterizerState(obj: DkCmdBuf, state: *const DkRasterizerState) void;
extern fn dkCmdBufBindColorState(obj: DkCmdBuf, state: *const DkColorState) void;
extern fn dkCmdBufBindColorWriteState(obj: DkCmdBuf, state: *const DkColorWriteState) void;
extern fn dkCmdBufBindDepthStencilState(obj: DkCmdBuf, state: *const DkDepthStencilState) void;
extern fn dkCmdBufBindVtxAttribState(obj: DkCmdBuf, attribs: [*]const DkVtxAttribState, numAttribs: u32) void;
extern fn dkCmdBufBindVtxBufferState(obj: DkCmdBuf, buffers: [*]const DkVtxBufferState, numBuffers: u32) void;
extern fn dkCmdBufBindVtxBuffers(obj: DkCmdBuf, firstId: u32, buffers: [*]const DkBufExtents, numBuffers: u32) void;
extern fn dkCmdBufSetViewports(obj: DkCmdBuf, firstId: u32, viewports: [*]const DkViewport, numViewports: u32) void;
extern fn dkCmdBufSetScissors(obj: DkCmdBuf, firstId: u32, scissors: [*]const DkScissor, numScissors: u32) void;
extern fn dkCmdBufClearColor(obj: DkCmdBuf, targetId: u32, clearMask: u32, clearData: *const anyopaque) void;
extern fn dkCmdBufDraw(obj: DkCmdBuf, prim: u32, vertexCount: u32, instanceCount: u32, firstVertex: u32, firstInstance: u32) void;

extern fn dkQueueCreate(maker: *const DkQueueMaker) DkQueue;
extern fn dkQueueDestroy(obj: DkQueue) void;
extern fn dkQueueWaitIdle(obj: DkQueue) void;
extern fn dkQueueSubmitCommands(obj: DkQueue, cmds: DkCmdList) void;
extern fn dkQueueAcquireImage(obj: DkQueue, swapchain: DkSwapchain) c_int;
extern fn dkQueuePresentImage(obj: DkQueue, swapchain: DkSwapchain, imageSlot: c_int) void;

extern fn dkShaderInitialize(obj: *DkShader, maker: *const DkShaderMaker) void;
extern fn dkShaderIsValid(obj: *const DkShader) bool;

extern fn dkImageLayoutInitialize(obj: *DkImageLayout, maker: *const DkImageLayoutMaker) void;
extern fn dkImageLayoutGetSize(obj: *const DkImageLayout) u64;
extern fn dkImageLayoutGetAlignment(obj: *const DkImageLayout) u32;
extern fn dkImageInitialize(obj: *DkImage, layout: *const DkImageLayout, memBlock: DkMemBlock, offset: u32) void;

extern fn dkSwapchainCreate(maker: *const DkSwapchainMaker) DkSwapchain;
extern fn dkSwapchainDestroy(obj: DkSwapchain) void;
extern fn dkSwapchainSetSwapInterval(obj: DkSwapchain, interval: u32) void;

const FB_COUNT = 2;
const FB_WIDTH = 1280;
const FB_HEIGHT = 720;
const CODE_MEM_SIZE = 512 * 1024;
const CMD_MEM_SIZE = 64 * 1024;
const MAX_VERTEX_ATTRIBS = 32;
const MAX_VERTEX_BUFFERS = 16;

const DK_MEMBLOCK_ALIGNMENT = 0x1000;
const DK_SHADER_CODE_ALIGNMENT = 0x100;

const DK_MEM_CPU_UNCACHED = 1 << 0;
const DK_MEM_GPU_CACHED = 2 << 2;
const DK_MEM_CODE = 1 << 4;
const DK_MEM_IMAGE = 1 << 5;

const DK_QUEUE_GRAPHICS = 1 << 0;
const DK_QUEUE_MEDIUM_PRIO = 0 << 2;
const DK_QUEUE_ENABLE_ZCULL = 0 << 4;
const DK_QUEUE_MIN_CMDMEM_SIZE = 0x10000;
const DK_PER_WARP_SCRATCH_MEM_ALIGNMENT = 0x200;
const DK_DEFAULT_MAX_COMPUTE_CONCURRENT_JOBS = 128;

const DK_IMAGE_TYPE_NONE = 0;
const DK_IMAGE_TYPE_2D = 2;
const DK_IMAGE_RGBA8_UNORM = 28;
const DK_IMAGE_USAGE_RENDER = 1 << 8;
const DK_IMAGE_USAGE_PRESENT = 1 << 10;
const DK_IMAGE_HW_COMPRESSION = 1 << 2;

const DK_STAGE_GRAPHICS_MASK = (1 << 5) - 1;
const DK_COLOR_MASK_RGBA = 0xF;

const DK_PRIMITIVE_LINES = 1;
const DK_PRIMITIVE_TRIANGLES = 4;

const DK_ATTR_SIZE_2X32 = 0x04;
const DK_ATTR_SIZE_3X32 = 0x02;
const DK_ATTR_SIZE_2X16 = 0x0f;
const DK_ATTR_SIZE_3X16 = 0x05;
const DK_ATTR_SIZE_2X8 = 0x18;
const DK_ATTR_SIZE_4X8 = 0x0a;

const DK_ATTR_TYPE_SNORM = 1;
const DK_ATTR_TYPE_UNORM = 2;
const DK_ATTR_TYPE_FLOAT = 7;

const DK_SWIZZLE_RED = 2;
const DK_SWIZZLE_GREEN = 3;
const DK_SWIZZLE_BLUE = 4;
const DK_SWIZZLE_ALPHA = 5;
const DK_DS_SOURCE_DEPTH = 0;

const PipelineData = struct {
    vertex_shader: DkShader,
    fragment_shader: DkShader,
    attribs: [MAX_VERTEX_ATTRIBS]DkVtxAttribState,
    attrib_count: u32,
    vtx_buffers: [MAX_VERTEX_BUFFERS]DkVtxBufferState,
    vtx_buffer_count: u32,
};

const MeshData = struct {
    pipeline: Pipeline.Handle,
    mem_block: DkMemBlock = null,
    gpu_addr: DkGpuAddr = 0,
    capacity: u32 = 0,
    size: u32 = 0,
};

var render_alloc: std.mem.Allocator = undefined;
var render_io: std.Io = undefined;

var device: DkDevice = null;
var render_queue: DkQueue = null;
var swapchain: DkSwapchain = null;
var framebuffer_mem: DkMemBlock = null;
var framebuffers: [FB_COUNT]DkImage = undefined;
var command_mem: DkMemBlock = null;
var command_buffer: DkCmdBuf = null;
var code_mem: DkMemBlock = null;
var code_offset: u32 = 0;

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var meshes = Util.CircularBuffer(MeshData, 8192).init();

var current_pipeline: Pipeline.Handle = 0;
var current_slot: c_int = -1;
var initialized: bool = false;
var clear_color: [4]f32 = .{ 0.0, 0.0, 0.0, 1.0 };
var vsync_enabled: bool = true;

pub fn setup(alloc: std.mem.Allocator, io: std.Io) void {
    render_alloc = alloc;
    render_io = io;
}

pub fn init() anyerror!void {
    _ = render_alloc;
    _ = render_io;

    var device_maker = DkDeviceMaker{
        .userData = null,
        .cbDebug = null,
        .cbAlloc = null,
        .cbFree = null,
        .flags = 0,
    };
    device = dkDeviceCreate(&device_maker);
    if (device == null) return error.GfxInitFailed;
    errdefer {
        dkDeviceDestroy(device);
        device = null;
    }

    try create_framebuffers();
    errdefer destroy_framebuffers();

    try create_code_memory();
    errdefer destroy_code_memory();

    try create_command_buffer();
    errdefer destroy_command_buffer();

    var queue_maker = DkQueueMaker{
        .device = device,
        .flags = DK_QUEUE_GRAPHICS | DK_QUEUE_MEDIUM_PRIO | DK_QUEUE_ENABLE_ZCULL,
        .commandMemorySize = DK_QUEUE_MIN_CMDMEM_SIZE,
        .flushThreshold = DK_QUEUE_MIN_CMDMEM_SIZE / 8,
        .perWarpScratchMemorySize = 4 * DK_PER_WARP_SCRATCH_MEM_ALIGNMENT,
        .maxConcurrentComputeJobs = DK_DEFAULT_MAX_COMPUTE_CONCURRENT_JOBS,
    };
    render_queue = dkQueueCreate(&queue_maker);
    if (render_queue == null) return error.GfxInitFailed;

    initialized = true;
    set_vsync(vsync_enabled);
}

pub fn deinit() void {
    if (render_queue) |_| dkQueueWaitIdle(render_queue);

    destroy_all_meshes();
    pipelines.clear();
    current_pipeline = 0;

    if (render_queue) |_| {
        dkQueueDestroy(render_queue);
        render_queue = null;
    }

    destroy_command_buffer();
    destroy_code_memory();
    destroy_framebuffers();

    if (device) |_| {
        dkDeviceDestroy(device);
        device = null;
    }

    initialized = false;
}

pub fn set_clear_color(r: f32, g: f32, b: f32, a: f32) void {
    clear_color = .{ r, g, b, a };
}

pub fn set_alpha_blend(_: bool) void {}
pub fn set_depth_write(_: bool) void {}
pub fn set_fog(_: bool, _: f32, _: f32, _: f32, _: f32, _: f32) void {}
pub fn set_clip_planes(_: bool) void {}
pub fn set_culling(_: bool) void {}
pub fn set_uv_offset(_: f32, _: f32) void {}
pub fn set_proj_matrix(_: *const Mat4) void {}
pub fn set_view_matrix(_: *const Mat4) void {}

pub fn start_frame() bool {
    if (!initialized or render_queue == null or swapchain == null or command_buffer == null) return false;

    // Single command-memory arena for the bring-up path. Wait before reuse so
    // the GPU cannot still be reading last frame's command list.
    dkQueueWaitIdle(render_queue);

    const slot = dkQueueAcquireImage(render_queue, swapchain);
    if (slot < 0 or slot >= FB_COUNT) return false;
    current_slot = slot;

    dkCmdBufClear(command_buffer);
    dkCmdBufAddMemory(command_buffer, command_mem, 0, CMD_MEM_SIZE);

    var color_view = imageView(&framebuffers[@intCast(slot)]);
    const color_targets = [_]*const DkImageView{&color_view};
    dkCmdBufBindRenderTargets(command_buffer, color_targets[0..].ptr, 1, null);

    const width = gfx.surface.get_width();
    const height = gfx.surface.get_height();
    if (width == 0 or height == 0) return false;

    var viewport = DkViewport{
        .x = 0.0,
        .y = 0.0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .near = 0.0,
        .far = 1.0,
    };
    var scissor = DkScissor{
        .x = 0,
        .y = 0,
        .width = width,
        .height = height,
    };
    dkCmdBufSetViewports(command_buffer, 0, @ptrCast(&viewport), 1);
    dkCmdBufSetScissors(command_buffer, 0, @ptrCast(&scissor), 1);
    dkCmdBufClearColor(command_buffer, 0, DK_COLOR_MASK_RGBA, &clear_color);

    bind_fixed_state();
    return true;
}

pub fn end_frame() void {
    if (!initialized or render_queue == null or swapchain == null or command_buffer == null or current_slot < 0) return;

    const list = dkCmdBufFinishList(command_buffer);
    dkQueueSubmitCommands(render_queue, list);
    dkQueuePresentImage(render_queue, swapchain, current_slot);
    current_slot = -1;
}

pub fn clear_depth() void {}

pub fn set_vsync(v: bool) void {
    vsync_enabled = v;
    if (swapchain) |_| dkSwapchainSetSwapInterval(swapchain, @intFromBool(v));
}

pub fn create_pipeline(layout: Pipeline.VertexLayout, v_shader: ?[:0]align(4) const u8, f_shader: ?[:0]align(4) const u8) anyerror!Pipeline.Handle {
    const vertex_code = v_shader orelse return error.InvalidShader;
    const fragment_code = f_shader orelse return error.InvalidShader;

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

    const pipeline = pipelines.add_element(data) orelse return error.OutOfPipelines;
    return @intCast(pipeline);
}

pub fn destroy_pipeline(pipeline: Pipeline.Handle) void {
    _ = pipelines.remove_element(pipeline);
    if (current_pipeline == pipeline) current_pipeline = 0;
}

pub fn bind_pipeline(pipeline: Pipeline.Handle) void {
    current_pipeline = pipeline;
}

pub fn create_mesh(pipeline: Pipeline.Handle) anyerror!Mesh.Handle {
    _ = pipelines.get_element(pipeline) orelse return error.InvalidPipeline;
    const mesh = meshes.add_element(.{ .pipeline = pipeline }) orelse return error.OutOfMeshes;
    return @intCast(mesh);
}

pub fn destroy_mesh(handle: Mesh.Handle) void {
    const mesh = meshes.get_element(handle) orelse return;
    if (mesh.mem_block) |_| dkMemBlockDestroy(mesh.mem_block);
    _ = meshes.remove_element(handle);
}

pub fn update_mesh(handle: Mesh.Handle, data: []const u8) void {
    var mesh = meshes.get_element(handle) orelse return;

    if (data.len == 0) {
        mesh.size = 0;
        meshes.update_element(handle, mesh);
        return;
    }

    const needed: u32 = @intCast(data.len);
    if (mesh.mem_block == null or mesh.capacity < needed) {
        if (mesh.mem_block) |_| dkMemBlockDestroy(mesh.mem_block);

        const alloc_size = alignForward(needed, DK_MEMBLOCK_ALIGNMENT);
        var maker = memBlockMaker(alloc_size, DK_MEM_CPU_UNCACHED | DK_MEM_GPU_CACHED);
        mesh.mem_block = dkMemBlockCreate(&maker);
        if (mesh.mem_block == null) {
            mesh.capacity = 0;
            mesh.size = 0;
            meshes.update_element(handle, mesh);
            return;
        }
        mesh.capacity = dkMemBlockGetSize(mesh.mem_block);
        mesh.gpu_addr = dkMemBlockGetGpuAddr(mesh.mem_block);
    }

    const dst: [*]u8 = @ptrCast(dkMemBlockGetCpuAddr(mesh.mem_block) orelse return);
    @memcpy(dst[0..data.len], data);
    _ = dkMemBlockFlushCpuCache(mesh.mem_block, 0, needed);

    mesh.size = needed;
    meshes.update_element(handle, mesh);
}

pub fn draw_mesh(handle: Mesh.Handle, _: *const Mat4, count: usize, primitive: Mesh.Primitive) void {
    if (!initialized or command_buffer == null) return;
    const mesh = meshes.get_element(handle) orelse return;
    if (mesh.mem_block == null or mesh.size == 0 or count == 0) return;

    const pipeline_handle = if (current_pipeline != 0) current_pipeline else mesh.pipeline;
    const pl = pipelines.get_element(pipeline_handle) orelse return;

    const shaders = [_]*const DkShader{ &pl.vertex_shader, &pl.fragment_shader };
    dkCmdBufBindShaders(command_buffer, DK_STAGE_GRAPHICS_MASK, shaders[0..].ptr, shaders.len);
    dkCmdBufBindVtxAttribState(command_buffer, pl.attribs[0..].ptr, pl.attrib_count);
    dkCmdBufBindVtxBufferState(command_buffer, pl.vtx_buffers[0..].ptr, pl.vtx_buffer_count);

    var extents: [MAX_VERTEX_BUFFERS]DkBufExtents = undefined;
    for (extents[0..pl.vtx_buffer_count]) |*extent| {
        extent.* = .{ .addr = mesh.gpu_addr, .size = mesh.size };
    }
    dkCmdBufBindVtxBuffers(command_buffer, 0, extents[0..].ptr, pl.vtx_buffer_count);

    dkCmdBufDraw(command_buffer, switch (primitive) {
        .triangles => DK_PRIMITIVE_TRIANGLES,
        .lines => DK_PRIMITIVE_LINES,
    }, @intCast(count), 1, 0, 0);
}

pub fn create_texture(_: u32, _: u32, _: []align(16) u8) anyerror!Texture.Handle {
    return 0;
}

pub fn update_texture(_: Texture.Handle, _: []align(16) u8) void {}
pub fn bind_texture(_: Texture.Handle) void {}
pub fn destroy_texture(_: Texture.Handle) void {}
pub fn force_texture_resident(_: Texture.Handle) void {}

fn create_framebuffers() !void {
    var layout_maker = DkImageLayoutMaker{
        .device = device,
        .type = DK_IMAGE_TYPE_2D,
        .flags = DK_IMAGE_USAGE_RENDER | DK_IMAGE_USAGE_PRESENT | DK_IMAGE_HW_COMPRESSION,
        .format = DK_IMAGE_RGBA8_UNORM,
        .msMode = 0,
        .dimensions = .{ FB_WIDTH, FB_HEIGHT, 0 },
        .mipLevels = 1,
        .pitchStride = 0,
    };

    var framebuffer_layout: DkImageLayout = undefined;
    dkImageLayoutInitialize(&framebuffer_layout, &layout_maker);

    const fb_align = dkImageLayoutGetAlignment(&framebuffer_layout);
    const fb_size = alignForward(@intCast(dkImageLayoutGetSize(&framebuffer_layout)), fb_align);
    var mem_maker = memBlockMaker(FB_COUNT * fb_size, DK_MEM_GPU_CACHED | DK_MEM_IMAGE);
    framebuffer_mem = dkMemBlockCreate(&mem_maker);
    if (framebuffer_mem == null) return error.GfxInitFailed;
    errdefer {
        dkMemBlockDestroy(framebuffer_mem);
        framebuffer_mem = null;
    }

    var swapchain_images: [FB_COUNT]*const DkImage = undefined;
    for (&framebuffers, 0..) |*fb, i| {
        dkImageInitialize(fb, &framebuffer_layout, framebuffer_mem, @intCast(i * fb_size));
        swapchain_images[i] = fb;
    }

    var swapchain_maker = DkSwapchainMaker{
        .device = device,
        .nativeWindow = nwindowGetDefault(),
        .pImages = swapchain_images[0..].ptr,
        .numImages = FB_COUNT,
    };
    swapchain = dkSwapchainCreate(&swapchain_maker);
    if (swapchain == null) return error.GfxInitFailed;
}

fn destroy_framebuffers() void {
    if (swapchain) |_| {
        dkSwapchainDestroy(swapchain);
        swapchain = null;
    }
    if (framebuffer_mem) |_| {
        dkMemBlockDestroy(framebuffer_mem);
        framebuffer_mem = null;
    }
}

fn create_code_memory() !void {
    var maker = memBlockMaker(CODE_MEM_SIZE, DK_MEM_CPU_UNCACHED | DK_MEM_GPU_CACHED | DK_MEM_CODE);
    code_mem = dkMemBlockCreate(&maker);
    if (code_mem == null) return error.GfxInitFailed;
    code_offset = 0;
}

fn destroy_code_memory() void {
    if (code_mem) |_| {
        dkMemBlockDestroy(code_mem);
        code_mem = null;
    }
    code_offset = 0;
}

fn create_command_buffer() !void {
    var mem_maker = memBlockMaker(CMD_MEM_SIZE, DK_MEM_CPU_UNCACHED | DK_MEM_GPU_CACHED);
    command_mem = dkMemBlockCreate(&mem_maker);
    if (command_mem == null) return error.GfxInitFailed;
    errdefer {
        dkMemBlockDestroy(command_mem);
        command_mem = null;
    }

    var cmd_maker = DkCmdBufMaker{
        .device = device,
        .userData = null,
        .cbAddMem = null,
    };
    command_buffer = dkCmdBufCreate(&cmd_maker);
    if (command_buffer == null) return error.GfxInitFailed;
}

fn destroy_command_buffer() void {
    if (command_buffer) |_| {
        dkCmdBufDestroy(command_buffer);
        command_buffer = null;
    }
    if (command_mem) |_| {
        dkMemBlockDestroy(command_mem);
        command_mem = null;
    }
}

fn destroy_all_meshes() void {
    for (&meshes.buffer) |*slot| {
        if (slot.*) |mesh| {
            if (mesh.mem_block) |_| dkMemBlockDestroy(mesh.mem_block);
            slot.* = null;
        }
    }
    meshes.clear();
}

fn memBlockMaker(size: u32, flags: u32) DkMemBlockMaker {
    return .{
        .device = device,
        .size = alignForward(size, DK_MEMBLOCK_ALIGNMENT),
        .flags = flags,
        .storage = null,
    };
}

fn load_shader(shader: *DkShader, code: []const u8) !void {
    if (code_mem == null) return error.GfxInitFailed;

    const offset = alignForward(code_offset, DK_SHADER_CODE_ALIGNMENT);
    const end = offset + alignForward(@intCast(code.len), DK_SHADER_CODE_ALIGNMENT);
    if (end > CODE_MEM_SIZE) return error.OutOfShaderMemory;

    const base: [*]u8 = @ptrCast(dkMemBlockGetCpuAddr(code_mem) orelse return error.GfxInitFailed);
    @memcpy(base[offset..][0..code.len], code);

    var maker = DkShaderMaker{
        .codeMem = code_mem,
        .control = null,
        .codeOffset = offset,
        .programId = 0,
    };
    dkShaderInitialize(shader, &maker);
    if (!dkShaderIsValid(shader)) return error.InvalidShader;

    code_offset = end;
}

fn init_layout(data: *PipelineData, layout: Pipeline.VertexLayout) !void {
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

fn vtxAttrib(attr: Pipeline.Attribute) DkVtxAttribState {
    const Format = struct {
        size: u32,
        kind: u32,
    };
    const fmt: Format = switch (attr.format) {
        .f32x2 => .{ .size = DK_ATTR_SIZE_2X32, .kind = DK_ATTR_TYPE_FLOAT },
        .f32x3 => .{ .size = DK_ATTR_SIZE_3X32, .kind = DK_ATTR_TYPE_FLOAT },
        .unorm8x2 => .{ .size = DK_ATTR_SIZE_2X8, .kind = DK_ATTR_TYPE_UNORM },
        .unorm8x4 => .{ .size = DK_ATTR_SIZE_4X8, .kind = DK_ATTR_TYPE_UNORM },
        .unorm16x2 => .{ .size = DK_ATTR_SIZE_2X16, .kind = DK_ATTR_TYPE_UNORM },
        .unorm16x3 => .{ .size = DK_ATTR_SIZE_3X16, .kind = DK_ATTR_TYPE_UNORM },
        .snorm16x2 => .{ .size = DK_ATTR_SIZE_2X16, .kind = DK_ATTR_TYPE_SNORM },
        .snorm16x3 => .{ .size = DK_ATTR_SIZE_3X16, .kind = DK_ATTR_TYPE_SNORM },
    };

    return .{ .bits = (@as(u32, attr.binding) & 0x1F) |
        ((@as(u32, @intCast(attr.offset)) & 0x3FFF) << 7) |
        ((fmt.size & 0x3F) << 21) |
        ((fmt.kind & 0x7) << 27) };
}

fn bind_fixed_state() void {
    const rasterizer = DkRasterizerState{
        // rasterizer on, fill both faces, no culling, CCW front face.
        .bits = 1 | (2 << 3) | (2 << 5) | (1 << 9) | (1 << 10),
    };
    const color = DkColorState{
        // logicOp=Copy, alphaCompare=Always, blending disabled.
        .bits = (3 << 8) | (8 << 16),
    };
    const color_write = DkColorWriteState{ .masks = 0xFFFF_FFFF };
    const depth = DkDepthStencilState{
        // No depth attachment in this milestone, so keep depth/stencil off.
        .bits0 = 8 << 4,
        .bits1 = 0,
    };

    dkCmdBufBindRasterizerState(command_buffer, &rasterizer);
    dkCmdBufBindColorState(command_buffer, &color);
    dkCmdBufBindColorWriteState(command_buffer, &color_write);
    dkCmdBufBindDepthStencilState(command_buffer, &depth);
}

fn imageView(image: *const DkImage) DkImageView {
    return .{
        .pImage = image,
        .type = DK_IMAGE_TYPE_NONE,
        .format = 0,
        .swizzle = .{ DK_SWIZZLE_RED, DK_SWIZZLE_GREEN, DK_SWIZZLE_BLUE, DK_SWIZZLE_ALPHA },
        .dsSource = DK_DS_SOURCE_DEPTH,
        .layerOffset = 0,
        .layerCount = 0,
        .mipLevelOffset = 0,
        .mipLevelCount = 0,
    };
}

fn alignForward(value: u32, alignment: u32) u32 {
    return std.mem.alignForward(u32, value, alignment);
}
