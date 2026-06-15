const std = @import("std");

pub const DkDevice_T = opaque {};
pub const DkMemBlock_T = opaque {};
pub const DkCmdBuf_T = opaque {};
pub const DkQueue_T = opaque {};
pub const DkSwapchain_T = opaque {};

pub const Event = extern struct {
    revent: u32,
    wevent: u32,
    autoclear: bool,
};

pub const DkDevice = ?*DkDevice_T;
pub const DkMemBlock = ?*DkMemBlock_T;
pub const DkCmdBuf = ?*DkCmdBuf_T;
pub const DkQueue = ?*DkQueue_T;
pub const DkSwapchain = ?*DkSwapchain_T;
pub const DkGpuAddr = u64;
pub const DkResHandle = u32;
pub const DkCmdList = usize;
pub const DkResult = c_int;
pub const DkDebugFunc = *const fn (?*anyopaque, [*:0]const u8, DkResult, [*:0]const u8) callconv(.c) void;

pub const DkDeviceMaker = extern struct {
    userData: ?*anyopaque,
    cbDebug: ?DkDebugFunc,
    cbAlloc: ?*const anyopaque,
    cbFree: ?*const anyopaque,
    flags: u32,
};

pub const DkMemBlockMaker = extern struct {
    device: DkDevice,
    size: u32,
    flags: u32,
    storage: ?*anyopaque,
};

pub const DkCmdBufMaker = extern struct {
    device: DkDevice,
    userData: ?*anyopaque,
    cbAddMem: ?*const anyopaque,
};

pub const DkQueueMaker = extern struct {
    device: DkDevice,
    flags: u32,
    commandMemorySize: u32,
    flushThreshold: u32,
    perWarpScratchMemorySize: u32,
    maxConcurrentComputeJobs: u32,
};

pub const DkShaderMaker = extern struct {
    codeMem: DkMemBlock,
    control: ?*const anyopaque,
    codeOffset: u32,
    programId: u32,
};

pub const DkImageLayoutMaker = extern struct {
    device: DkDevice,
    type: u32,
    flags: u32,
    format: u32,
    msMode: u32,
    dimensions: [3]u32,
    mipLevels: u32,
    pitchStride: u32,
};

pub const DkSwapchainMaker = extern struct {
    device: DkDevice,
    nativeWindow: ?*anyopaque,
    pImages: [*]const *const DkImage,
    numImages: u32,
};

pub const DkShader = extern struct {
    storage: [16]u64,
};

pub const DkImageLayout = extern struct {
    storage: [16]u64,
};

pub const DkImage = extern struct {
    storage: [16]u64,
};

pub const DkImageDescriptor = extern struct {
    storage: [8]u32,
};

pub const DkSamplerDescriptor = extern struct {
    storage: [8]u32,
};

pub const DkFence = extern struct {
    storage: [8]u64,
};

pub const DkImageView = extern struct {
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

pub const DkViewport = extern struct {
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    near: f32,
    far: f32,
};

pub const DkScissor = extern struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
};

pub const DkRasterizerState = extern struct {
    bits: u32,
};

pub const DkColorState = extern struct {
    bits: u32,
};

pub const DkColorWriteState = extern struct {
    masks: u32,
};

pub const DkDepthStencilState = extern struct {
    bits0: u32,
    bits1: u32,
};

pub const DkBlendState = extern struct {
    bits: u32,
};

pub const DkVtxAttribState = extern struct {
    bits: u32,
};

pub const DkVtxBufferState = extern struct {
    stride: u32,
    divisor: u32,
};

pub const DkBufExtents = extern struct {
    addr: DkGpuAddr,
    size: u32,
};

pub const DkCopyBuf = extern struct {
    addr: DkGpuAddr,
    rowLength: u32,
    imageHeight: u32,
};

pub const DkImageRect = extern struct {
    x: u32,
    y: u32,
    z: u32,
    width: u32,
    height: u32,
    depth: u32,
};

pub const DkSampler = extern struct {
    minFilter: u32,
    magFilter: u32,
    mipFilter: u32,
    wrapMode: [3]u32,
    lodClampMin: f32,
    lodClampMax: f32,
    lodBias: f32,
    lodSnap: f32,
    compareEnable: bool,
    compareOp: u32,
    borderColor: [4]extern union {
        value_f: f32,
        value_ui: u32,
        value_i: i32,
    },
    maxAnisotropy: f32,
    reductionMode: u32,
};

pub extern fn nwindowGetDefault() ?*anyopaque;
pub extern fn appletGetGpuErrorDetectedSystemEvent(out_event: *Event) u32;
pub extern fn eventWait(event: *Event, timeout: u64) u32;
pub extern fn eventClose(event: *Event) void;

pub extern fn dkDeviceCreate(maker: *const DkDeviceMaker) DkDevice;
pub extern fn dkDeviceDestroy(obj: DkDevice) void;

pub extern fn dkMemBlockCreate(maker: *const DkMemBlockMaker) DkMemBlock;
pub extern fn dkMemBlockDestroy(obj: DkMemBlock) void;
pub extern fn dkMemBlockGetCpuAddr(obj: DkMemBlock) ?*anyopaque;
pub extern fn dkMemBlockGetGpuAddr(obj: DkMemBlock) DkGpuAddr;
pub extern fn dkMemBlockGetSize(obj: DkMemBlock) u32;
pub extern fn dkMemBlockFlushCpuCache(obj: DkMemBlock, offset: u32, size: u32) u32;

pub extern fn dkFenceWait(obj: *DkFence, timeout_ns: i64) DkResult;

pub extern fn dkCmdBufCreate(maker: *const DkCmdBufMaker) DkCmdBuf;
pub extern fn dkCmdBufDestroy(obj: DkCmdBuf) void;
pub extern fn dkCmdBufAddMemory(obj: DkCmdBuf, mem: DkMemBlock, offset: u32, size: u32) void;
pub extern fn dkCmdBufFinishList(obj: DkCmdBuf) DkCmdList;
pub extern fn dkCmdBufClear(obj: DkCmdBuf) void;
pub extern fn dkCmdBufBeginCaptureCmds(obj: DkCmdBuf, storage: [*]u32, max_words: u32) void;
pub extern fn dkCmdBufEndCaptureCmds(obj: DkCmdBuf) u32;
pub extern fn dkCmdBufCallList(obj: DkCmdBuf, list: DkCmdList) void;
pub extern fn dkCmdBufSignalFence(obj: DkCmdBuf, fence: *DkFence, flush: bool) void;
pub extern fn dkCmdBufBarrier(obj: DkCmdBuf, mode: u32, invalidateFlags: u32) void;
pub extern fn dkCmdBufBindShaders(obj: DkCmdBuf, stageMask: u32, shaders: [*]const *const DkShader, numShaders: u32) void;
pub extern fn dkCmdBufBindRenderTargets(obj: DkCmdBuf, colorTargets: [*]const *const DkImageView, numColorTargets: u32, depthTarget: ?*const DkImageView) void;
pub extern fn dkCmdBufBindRasterizerState(obj: DkCmdBuf, state: *const DkRasterizerState) void;
pub extern fn dkCmdBufBindColorState(obj: DkCmdBuf, state: *const DkColorState) void;
pub extern fn dkCmdBufBindColorWriteState(obj: DkCmdBuf, state: *const DkColorWriteState) void;
pub extern fn dkCmdBufBindDepthStencilState(obj: DkCmdBuf, state: *const DkDepthStencilState) void;
pub extern fn dkCmdBufBindBlendStates(obj: DkCmdBuf, firstId: u32, states: [*]const DkBlendState, numStates: u32) void;
pub extern fn dkCmdBufBindVtxAttribState(obj: DkCmdBuf, attribs: [*]const DkVtxAttribState, numAttribs: u32) void;
pub extern fn dkCmdBufBindVtxBufferState(obj: DkCmdBuf, buffers: [*]const DkVtxBufferState, numBuffers: u32) void;
pub extern fn dkCmdBufBindVtxBuffers(obj: DkCmdBuf, firstId: u32, buffers: [*]const DkBufExtents, numBuffers: u32) void;
pub extern fn dkCmdBufBindUniformBuffers(obj: DkCmdBuf, stage: u32, firstId: u32, buffers: [*]const DkBufExtents, numBuffers: u32) void;
pub extern fn dkCmdBufSetViewports(obj: DkCmdBuf, firstId: u32, viewports: [*]const DkViewport, numViewports: u32) void;
pub extern fn dkCmdBufSetScissors(obj: DkCmdBuf, firstId: u32, scissors: [*]const DkScissor, numScissors: u32) void;
pub extern fn dkCmdBufClearColor(obj: DkCmdBuf, targetId: u32, clearMask: u32, clearData: *const anyopaque) void;
pub extern fn dkCmdBufClearDepthStencil(obj: DkCmdBuf, clearDepth: bool, depthValue: f32, stencilMask: u8, stencilValue: u8) void;
pub extern fn dkCmdBufDiscardDepthStencil(obj: DkCmdBuf) void;
pub extern fn dkCmdBufPushConstants(obj: DkCmdBuf, uboAddr: DkGpuAddr, uboSize: u32, offset: u32, size: u32, data: *const anyopaque) void;
pub extern fn dkCmdBufPushData(obj: DkCmdBuf, addr: DkGpuAddr, data: *const anyopaque, size: u32) void;
pub extern fn dkCmdBufCopyBufferToImage(obj: DkCmdBuf, src: *const DkCopyBuf, dstView: *const DkImageView, dstRect: *const DkImageRect, flags: u32) void;
pub extern fn dkCmdBufReportValue(obj: DkCmdBuf, value: u32, addr: DkGpuAddr) void;
pub extern fn dkCmdBufBindImageDescriptorSet(obj: DkCmdBuf, setAddr: DkGpuAddr, numDescriptors: u32) void;
pub extern fn dkCmdBufBindSamplerDescriptorSet(obj: DkCmdBuf, setAddr: DkGpuAddr, numDescriptors: u32) void;
pub extern fn dkCmdBufBindTextures(obj: DkCmdBuf, stage: u32, firstId: u32, handles: [*]const DkResHandle, numHandles: u32) void;
pub extern fn dkCmdBufDraw(obj: DkCmdBuf, prim: u32, vertexCount: u32, instanceCount: u32, firstVertex: u32, firstInstance: u32) void;

pub extern fn dkQueueCreate(maker: *const DkQueueMaker) DkQueue;
pub extern fn dkQueueDestroy(obj: DkQueue) void;
pub extern fn dkQueueIsInErrorState(obj: DkQueue) bool;
pub extern fn dkQueueWaitIdle(obj: DkQueue) void;
pub extern fn dkQueueSignalFence(obj: DkQueue, fence: *DkFence, flush: bool) void;
pub extern fn dkQueueSubmitCommands(obj: DkQueue, cmds: DkCmdList) void;
pub extern fn dkQueueFlush(obj: DkQueue) void;
pub extern fn dkQueueAcquireImage(obj: DkQueue, swapchain: DkSwapchain) c_int;
pub extern fn dkQueuePresentImage(obj: DkQueue, swapchain: DkSwapchain, imageSlot: c_int) void;

pub extern fn dkShaderInitialize(obj: *DkShader, maker: *const DkShaderMaker) void;
pub extern fn dkShaderIsValid(obj: *const DkShader) bool;

pub extern fn dkImageLayoutInitialize(obj: *DkImageLayout, maker: *const DkImageLayoutMaker) void;
pub extern fn dkImageLayoutGetSize(obj: *const DkImageLayout) u64;
pub extern fn dkImageLayoutGetAlignment(obj: *const DkImageLayout) u32;
pub extern fn dkImageInitialize(obj: *DkImage, layout: *const DkImageLayout, memBlock: DkMemBlock, offset: u32) void;
pub extern fn dkImageDescriptorInitialize(obj: *DkImageDescriptor, view: *const DkImageView, usesLoadOrStore: bool, decayMS: bool) void;
pub extern fn dkSamplerDescriptorInitialize(obj: *DkSamplerDescriptor, sampler: *const DkSampler) void;

pub extern fn dkSwapchainCreate(maker: *const DkSwapchainMaker) DkSwapchain;
pub extern fn dkSwapchainDestroy(obj: DkSwapchain) void;
pub extern fn dkSwapchainSetSwapInterval(obj: DkSwapchain, interval: u32) void;

pub const ResultSuccess: DkResult = 0;
pub const ResultTimeout: DkResult = 2;
pub const FenceWaitForever: i64 = -1;

pub const MemBlockAlignment = 0x1000;
pub const CmdMemAlignment = 4;
pub const ShaderCodeAlignment = 0x100;
pub const UniformBufferAlignment = 0x100;
pub const ImageDescriptorAlignment = 0x20;
pub const ImageDescriptorSize = 0x20;
pub const SamplerDescriptorSize = 0x20;
pub const ImageLinearStrideAlignment = 0x20;

pub const MemCpuUncached = 1 << 0;
pub const MemCpuCached = 2 << 0;
pub const MemGpuUncached = 1 << 2;
pub const MemGpuCached = 2 << 2;
pub const MemCode = 1 << 4;
pub const MemImage = 1 << 5;
pub const MemZeroFillInit = 1 << 8;

pub const QueueGraphics = 1 << 0;
pub const QueueMediumPrio = 0 << 2;
pub const QueueEnableZcull = 0 << 4;
pub const QueueDisableZcull = 1 << 4;
pub const QueueMinCmdMemSize = 0x10000;
pub const PerWarpScratchMemAlignment = 0x200;
pub const DefaultMaxComputeConcurrentJobs = 128;

pub const ImageTypeNone = 0;
pub const ImageType2d = 2;
pub const ImageRgba8Unorm = 28;
pub const ImageZ24S8 = 44;
pub const ImageUsageRender = 1 << 8;
pub const ImageUsagePresent = 1 << 10;
pub const ImageUsage2dEngine = 1 << 11;
pub const ImageHwCompression = 1 << 2;

pub const BarrierFragments = 2;
pub const BarrierPrimitives = 3;
pub const BarrierFull = 4;
pub const InvalidateImage = 1 << 0;
pub const InvalidateShader = 1 << 1;
pub const InvalidateDescriptors = 1 << 2;
pub const InvalidateZcull = 1 << 3;
pub const InvalidateL2Cache = 1 << 4;

pub const StageGraphicsMask = (1 << 5) - 1;
pub const StageVertex = 0;
pub const StageFragment = 4;
pub const ColorMaskRgba = 0xF;

pub const FilterNearest = 1;
pub const MipFilterNone = 1;
pub const WrapRepeat = 0;
pub const WrapClampToEdge = 2;
pub const CompareLess = 2;
pub const CompareAlways = 8;
pub const SamplerReductionWeightedAverage = 0;
pub const PolygonModeFill = 2;
pub const FaceNone = 0;
pub const FaceBack = 2;
pub const FrontFaceCcw = 1;
pub const ProvokingVertexLast = 1;
pub const LogicOpCopy = 3;
pub const BlendOpAdd = 1;
pub const BlendFactorZero = 1;
pub const BlendFactorOne = 2;
pub const BlendFactorSrcAlpha = 5;
pub const BlendFactorInvSrcAlpha = 6;

pub const PrimitiveTriangles = 4;

pub const AttrSize2x32 = 0x04;
pub const AttrSize3x32 = 0x02;
pub const AttrSize2x16 = 0x0f;
pub const AttrSize3x16 = 0x05;
pub const AttrSize2x8 = 0x18;
pub const AttrSize4x8 = 0x0a;

pub const AttrTypeSnorm = 1;
pub const AttrTypeUnorm = 2;
pub const AttrTypeFloat = 7;

pub const SwizzleRed = 2;
pub const SwizzleGreen = 3;
pub const SwizzleBlue = 4;
pub const SwizzleAlpha = 5;
pub const DsSourceDepth = 0;

pub fn emptyFence() DkFence {
    return .{ .storage = @splat(0) };
}

pub fn alignForward(value: u32, alignment: u32) u32 {
    return std.mem.alignForward(u32, value, alignment);
}

pub fn imageView(image: *const DkImage) DkImageView {
    return .{
        .pImage = image,
        .type = ImageTypeNone,
        .format = 0,
        .swizzle = .{ SwizzleRed, SwizzleGreen, SwizzleBlue, SwizzleAlpha },
        .dsSource = DsSourceDepth,
        .layerOffset = 0,
        .layerCount = 0,
        .mipLevelOffset = 0,
        .mipLevelCount = 0,
    };
}

pub fn makeTextureHandle(image_id: u32, sampler_id: u32) DkResHandle {
    return (image_id & ((1 << 20) - 1)) | (sampler_id << 20);
}

pub fn depthStencilBits(depth_write_enabled: bool) DkDepthStencilState {
    const bits0: u32 = 1 |
        (@as(u32, @intFromBool(depth_write_enabled)) << 1) |
        (CompareLess << 4);
    const bits1: u32 = 1 |
        (3 << 4) |
        (1 << 8) |
        (CompareAlways << 12) |
        (1 << 16) |
        (3 << 20) |
        (1 << 24) |
        (CompareAlways << 28);
    return .{ .bits0 = bits0, .bits1 = bits1 };
}
