const std = @import("std");

const c = @cImport({
    @cUndef("_GNU_SOURCE");
    @cUndef("_DEFAULT_SOURCE");
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("wint_t", "__WINT_TYPE__");
    @cDefine("__SWITCH__", "1");
    @cDefine("__thread", "");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("deko3d.h");
});

pub const DkDevice = c.DkDevice;
pub const DkMemBlock = c.DkMemBlock;
pub const DkCmdBuf = c.DkCmdBuf;
pub const DkQueue = c.DkQueue;
pub const DkSwapchain = c.DkSwapchain;
pub const DkGpuAddr = c.DkGpuAddr;
pub const DkResHandle = c.DkResHandle;
pub const DkCmdList = c.DkCmdList;
pub const DkResult = c.DkResult;

pub const Event = extern struct {
    revent: u32,
    wevent: u32,
    autoclear: bool,
};
pub const DkDeviceMaker = c.DkDeviceMaker;
pub const DkMemBlockMaker = c.DkMemBlockMaker;
pub const DkCmdBufMaker = c.DkCmdBufMaker;
pub const DkQueueMaker = c.DkQueueMaker;
pub const DkShaderMaker = c.DkShaderMaker;
pub const DkImageLayoutMaker = c.DkImageLayoutMaker;
pub const DkSwapchainMaker = c.DkSwapchainMaker;
pub const DkShader = c.DkShader;
pub const DkImageLayout = c.DkImageLayout;
pub const DkImage = c.DkImage;
pub const DkImageDescriptor = c.DkImageDescriptor;
pub const DkSamplerDescriptor = c.DkSamplerDescriptor;
pub const DkImageView = c.DkImageView;
pub const DkViewport = c.DkViewport;
pub const DkScissor = c.DkScissor;
pub const DkVtxBufferState = c.DkVtxBufferState;
pub const DkBufExtents = c.DkBufExtents;
pub const DkCopyBuf = c.DkCopyBuf;
pub const DkImageRect = c.DkImageRect;
pub const DkSampler = c.DkSampler;
pub const DkIdxFormat = c.DkIdxFormat;
pub const IdxFormatUint16 = c.DkIdxFormat_Uint16;

// Zig demotes deko3d's C bitfield structs to opaque types during @cImport.
// Keep only these raw ABI mirrors locally so state setup remains explicit.
pub const DkFence = c.DkFence;
pub const DkRasterizerState = extern struct { bits: u32 };
pub const DkColorState = extern struct { bits: u32 };
pub const DkColorWriteState = c.DkColorWriteState;
pub const DkDepthStencilState = extern struct { bits0: u32, bits1: u32 };
pub const DkBlendState = extern struct { bits: u32 };
pub const DkVtxAttribState = extern struct { bits: u32 };

pub extern fn nwindowGetDefault() ?*anyopaque;
pub extern fn nwindowSetDimensions(nw: ?*anyopaque, width: u32, height: u32) u32;
pub extern fn nwindowReleaseBuffers(nw: ?*anyopaque) u32;
pub extern fn appletGetGpuErrorDetectedSystemEvent(out_event: *Event) u32;
pub extern fn eventWait(event: *Event, timeout: u64) u32;
pub extern fn eventClose(event: *Event) void;

pub const dkDeviceCreate = c.dkDeviceCreate;
pub const dkDeviceDestroy = c.dkDeviceDestroy;
pub const dkMemBlockCreate = c.dkMemBlockCreate;
pub const dkMemBlockDestroy = c.dkMemBlockDestroy;
pub const dkMemBlockGetCpuAddr = c.dkMemBlockGetCpuAddr;
pub const dkMemBlockGetGpuAddr = c.dkMemBlockGetGpuAddr;
pub const dkMemBlockGetSize = c.dkMemBlockGetSize;
pub const dkMemBlockFlushCpuCache = c.dkMemBlockFlushCpuCache;
pub const dkFenceWait = c.dkFenceWait;
pub const dkCmdBufCreate = c.dkCmdBufCreate;
pub const dkCmdBufDestroy = c.dkCmdBufDestroy;
pub const dkCmdBufAddMemory = c.dkCmdBufAddMemory;
pub const dkCmdBufFinishList = c.dkCmdBufFinishList;
pub const dkCmdBufClear = c.dkCmdBufClear;
pub const dkCmdBufBeginCaptureCmds = c.dkCmdBufBeginCaptureCmds;
pub const dkCmdBufEndCaptureCmds = c.dkCmdBufEndCaptureCmds;
pub const dkCmdBufCallList = c.dkCmdBufCallList;
pub const dkCmdBufSignalFence = c.dkCmdBufSignalFence;
pub const dkCmdBufBarrier = c.dkCmdBufBarrier;
pub const dkCmdBufBindVtxBufferState = c.dkCmdBufBindVtxBufferState;
pub const dkCmdBufBindVtxBuffers = c.dkCmdBufBindVtxBuffers;
pub const dkCmdBufBindIdxBuffer = c.dkCmdBufBindIdxBuffer;
pub const dkCmdBufBindUniformBuffers = c.dkCmdBufBindUniformBuffers;
pub const dkCmdBufSetViewports = c.dkCmdBufSetViewports;
pub const dkCmdBufSetScissors = c.dkCmdBufSetScissors;
pub const dkCmdBufClearColor = c.dkCmdBufClearColor;
pub const dkCmdBufClearDepthStencil = c.dkCmdBufClearDepthStencil;
pub const dkCmdBufDiscardDepthStencil = c.dkCmdBufDiscardDepthStencil;
pub const dkCmdBufPushConstants = c.dkCmdBufPushConstants;
pub const dkCmdBufPushData = c.dkCmdBufPushData;
pub const dkCmdBufCopyBufferToImage = c.dkCmdBufCopyBufferToImage;
pub const dkCmdBufReportValue = c.dkCmdBufReportValue;
pub const dkCmdBufBindImageDescriptorSet = c.dkCmdBufBindImageDescriptorSet;
pub const dkCmdBufBindSamplerDescriptorSet = c.dkCmdBufBindSamplerDescriptorSet;
pub const dkCmdBufBindTextures = c.dkCmdBufBindTextures;
pub const dkCmdBufDraw = c.dkCmdBufDraw;
pub const dkCmdBufDrawIndexed = c.dkCmdBufDrawIndexed;
pub const dkQueueCreate = c.dkQueueCreate;
pub const dkQueueDestroy = c.dkQueueDestroy;
pub const dkQueueIsInErrorState = c.dkQueueIsInErrorState;
pub const dkQueueWaitIdle = c.dkQueueWaitIdle;
pub const dkQueueSignalFence = c.dkQueueSignalFence;
pub const dkQueueSubmitCommands = c.dkQueueSubmitCommands;
pub const dkQueueFlush = c.dkQueueFlush;
pub const dkQueueAcquireImage = c.dkQueueAcquireImage;
pub const dkQueuePresentImage = c.dkQueuePresentImage;
pub const dkShaderInitialize = c.dkShaderInitialize;
pub const dkShaderIsValid = c.dkShaderIsValid;
pub const dkImageLayoutInitialize = c.dkImageLayoutInitialize;
pub const dkImageLayoutGetSize = c.dkImageLayoutGetSize;
pub const dkImageLayoutGetAlignment = c.dkImageLayoutGetAlignment;
pub const dkImageInitialize = c.dkImageInitialize;
pub const dkImageDescriptorInitialize = c.dkImageDescriptorInitialize;
pub const dkSamplerDescriptorInitialize = c.dkSamplerDescriptorInitialize;
pub const dkSamplerDefaults = c.dkSamplerDefaults;
pub const dkSwapchainCreate = c.dkSwapchainCreate;
pub const dkSwapchainDestroy = c.dkSwapchainDestroy;
pub const dkSwapchainSetSwapInterval = c.dkSwapchainSetSwapInterval;

pub fn dkCmdBufBindShaders(obj: DkCmdBuf, stage_mask: u32, shaders: [*]const *const DkShader, num_shaders: u32) void {
    c.dkCmdBufBindShaders(obj, stage_mask, @ptrCast(shaders), num_shaders);
}

pub fn dkCmdBufBindRenderTargets(obj: DkCmdBuf, color_targets: [*]const *const DkImageView, num_color_targets: u32, depth_target: ?*const DkImageView) void {
    c.dkCmdBufBindRenderTargets(obj, @ptrCast(color_targets), num_color_targets, depth_target);
}

pub fn dkCmdBufBindRasterizerState(obj: DkCmdBuf, state: *const DkRasterizerState) void {
    c.dkCmdBufBindRasterizerState(obj, @ptrCast(state));
}

pub fn dkCmdBufBindColorState(obj: DkCmdBuf, state: *const DkColorState) void {
    c.dkCmdBufBindColorState(obj, @ptrCast(state));
}

pub fn dkCmdBufBindColorWriteState(obj: DkCmdBuf, state: *const DkColorWriteState) void {
    c.dkCmdBufBindColorWriteState(obj, state);
}

pub fn dkCmdBufBindDepthStencilState(obj: DkCmdBuf, state: *const DkDepthStencilState) void {
    c.dkCmdBufBindDepthStencilState(obj, @ptrCast(state));
}

pub fn dkCmdBufBindBlendStates(obj: DkCmdBuf, first_id: u32, states: *const DkBlendState, num_states: u32) void {
    c.dkCmdBufBindBlendStates(obj, first_id, @ptrCast(states), num_states);
}

pub fn dkCmdBufBindVtxAttribState(obj: DkCmdBuf, attribs: [*]const DkVtxAttribState, num_attribs: u32) void {
    c.dkCmdBufBindVtxAttribState(obj, @ptrCast(attribs), num_attribs);
}

pub const ResultSuccess: DkResult = c.DkResult_Success;
pub const ResultTimeout: DkResult = c.DkResult_Timeout;
pub const FenceWaitForever: i64 = -1;

pub const MemBlockAlignment = c.DK_MEMBLOCK_ALIGNMENT;
pub const CmdMemAlignment = c.DK_CMDMEM_ALIGNMENT;
pub const ShaderCodeAlignment = c.DK_SHADER_CODE_ALIGNMENT;
pub const UniformBufferAlignment = c.DK_UNIFORM_BUF_ALIGNMENT;
pub const ImageDescriptorAlignment = c.DK_IMAGE_DESCRIPTOR_ALIGNMENT;
pub const ImageDescriptorSize = @sizeOf(DkImageDescriptor);
pub const SamplerDescriptorSize = @sizeOf(DkSamplerDescriptor);
pub const ImageLinearStrideAlignment = c.DK_IMAGE_LINEAR_STRIDE_ALIGNMENT;

pub const MemCpuUncached = c.DkMemBlockFlags_CpuUncached;
pub const MemCpuCached = c.DkMemBlockFlags_CpuCached;
pub const MemGpuUncached = c.DkMemBlockFlags_GpuUncached;
pub const MemGpuCached = c.DkMemBlockFlags_GpuCached;
pub const MemCode = c.DkMemBlockFlags_Code;
pub const MemImage = c.DkMemBlockFlags_Image;
pub const MemZeroFillInit = c.DkMemBlockFlags_ZeroFillInit;

pub const QueueGraphics = c.DkQueueFlags_Graphics;
pub const QueueMediumPrio = c.DkQueueFlags_MediumPrio;
pub const QueueEnableZcull = c.DkQueueFlags_EnableZcull;
pub const QueueDisableZcull = c.DkQueueFlags_DisableZcull;
pub const QueueMinCmdMemSize = c.DK_QUEUE_MIN_CMDMEM_SIZE;
pub const PerWarpScratchMemAlignment = c.DK_PER_WARP_SCRATCH_MEM_ALIGNMENT;
pub const DefaultMaxComputeConcurrentJobs = c.DK_DEFAULT_MAX_COMPUTE_CONCURRENT_JOBS;

pub const ImageTypeNone = c.DkImageType_None;
pub const ImageType2d = c.DkImageType_2D;
pub const ImageRgba8Unorm = c.DkImageFormat_RGBA8_Unorm;
pub const ImageZ24S8 = c.DkImageFormat_Z24S8;
pub const ImageUsageRender = c.DkImageFlags_UsageRender;
pub const ImageUsagePresent = c.DkImageFlags_UsagePresent;
pub const ImageUsage2dEngine = c.DkImageFlags_Usage2DEngine;
pub const ImageHwCompression = c.DkImageFlags_HwCompression;

pub const BarrierFragments = c.DkBarrier_Fragments;
pub const BarrierPrimitives = c.DkBarrier_Primitives;
pub const BarrierFull = c.DkBarrier_Full;
pub const InvalidateImage = c.DkInvalidateFlags_Image;
pub const InvalidateShader = c.DkInvalidateFlags_Shader;
pub const InvalidateDescriptors = c.DkInvalidateFlags_Descriptors;
pub const InvalidateZcull = c.DkInvalidateFlags_Zcull;
pub const InvalidateL2Cache = c.DkInvalidateFlags_L2Cache;

pub const StageGraphicsMask = c.DkStageFlag_GraphicsMask;
pub const StageVertex = c.DkStage_Vertex;
pub const StageFragment = c.DkStage_Fragment;
pub const ColorMaskRgba = c.DkColorMask_RGBA;

pub const FilterNearest = c.DkFilter_Nearest;
pub const MipFilterNone = c.DkMipFilter_None;
pub const WrapRepeat = c.DkWrapMode_Repeat;
pub const WrapClampToEdge = c.DkWrapMode_ClampToEdge;
pub const CompareLess = c.DkCompareOp_Less;
pub const CompareAlways = c.DkCompareOp_Always;
pub const SamplerReductionWeightedAverage = c.DkSamplerReduction_WeightedAverage;
pub const PolygonModeFill = c.DkPolygonMode_Fill;
pub const FaceNone = c.DkFace_None;
pub const FaceBack = c.DkFace_Back;
pub const FrontFaceCcw = c.DkFrontFace_CCW;
pub const ProvokingVertexLast = c.DkProvokingVertex_Last;
pub const LogicOpCopy = c.DkLogicOp_Copy;
pub const BlendOpAdd = c.DkBlendOp_Add;
pub const BlendFactorZero = c.DkBlendFactor_Zero;
pub const BlendFactorOne = c.DkBlendFactor_One;
pub const BlendFactorSrcAlpha = c.DkBlendFactor_SrcAlpha;
pub const BlendFactorInvSrcAlpha = c.DkBlendFactor_InvSrcAlpha;

pub const PrimitiveTriangles = c.DkPrimitive_Triangles;

pub const AttrSize2x32 = c.DkVtxAttribSize_2x32;
pub const AttrSize3x32 = c.DkVtxAttribSize_3x32;
pub const AttrSize2x16 = c.DkVtxAttribSize_2x16;
pub const AttrSize3x16 = c.DkVtxAttribSize_3x16;
pub const AttrSize2x8 = c.DkVtxAttribSize_2x8;
pub const AttrSize4x8 = c.DkVtxAttribSize_4x8;

pub const AttrTypeSnorm = c.DkVtxAttribType_Snorm;
pub const AttrTypeUnorm = c.DkVtxAttribType_Unorm;
pub const AttrTypeFloat = c.DkVtxAttribType_Float;

pub fn emptyFence() DkFence {
    return .{ ._storage = @splat(0) };
}

pub fn alignForward(value: u32, alignment: u32) u32 {
    return std.mem.alignForward(u32, value, alignment);
}

pub fn imageView(image: *const DkImage) DkImageView {
    return .{
        .pImage = image,
        .type = @intCast(ImageTypeNone),
        .format = 0,
        .swizzle = .{
            @intCast(c.DkImageSwizzle_Red),
            @intCast(c.DkImageSwizzle_Green),
            @intCast(c.DkImageSwizzle_Blue),
            @intCast(c.DkImageSwizzle_Alpha),
        },
        .dsSource = @intCast(c.DkDsSource_Depth),
        .layerOffset = 0,
        .layerCount = 0,
        .mipLevelOffset = 0,
        .mipLevelCount = 0,
    };
}

pub fn defaultSampler() DkSampler {
    return .{
        .minFilter = @intCast(FilterNearest),
        .magFilter = @intCast(FilterNearest),
        .mipFilter = @intCast(MipFilterNone),
        .wrapMode = .{
            @intCast(WrapRepeat),
            @intCast(WrapRepeat),
            @intCast(WrapRepeat),
        },
        .lodClampMin = 0.0,
        .lodClampMax = 1000.0,
        .lodBias = 0.0,
        .lodSnap = 0.0,
        .compareEnable = false,
        .compareOp = @intCast(CompareLess),
        .borderColor = .{
            .{ .value_ui = 0 },
            .{ .value_ui = 0 },
            .{ .value_ui = 0 },
            .{ .value_ui = 0 },
        },
        .maxAnisotropy = 1.0,
        .reductionMode = @intCast(SamplerReductionWeightedAverage),
    };
}

pub fn makeTextureHandle(image_id: u32, sampler_id: u32) DkResHandle {
    return c.dkMakeTextureHandle(image_id, sampler_id);
}

pub fn depthStencilBits(depth_write_enabled: bool) DkDepthStencilState {
    const bits0: u32 = 1 |
        (@as(u32, @intFromBool(depth_write_enabled)) << 1) |
        (@as(u32, @intCast(CompareLess)) << 4);
    const bits1: u32 = 1 |
        (3 << 4) |
        (1 << 8) |
        (@as(u32, @intCast(CompareAlways)) << 12) |
        (1 << 16) |
        (3 << 20) |
        (1 << 24) |
        (@as(u32, @intCast(CompareAlways)) << 28);
    return .{ .bits0 = bits0, .bits1 = bits1 };
}
