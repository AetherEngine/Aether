const std = @import("std");
const Mat4 = @import("math/math.zig").Mat4;
const Graphics = @import("graphics/graphics.zig");
const Mesh = Graphics.mesh;
const Texture = Graphics.texture;
const RenderState = Graphics.RenderState;

pub const InitError = error{
    OutOfMemory,
    GfxInitFailed,
    SurfaceInitFailed,
    VulkanNotSupported,
    NoSuitableDeviceFound,
    NoSuitableMemoryType,
    SwapchainCreationFailed,
    ImageAcquireFailed,
    PipelineCreationFailed,
    WebGlInitFailed,
    InvalidShader,
    OutOfShaderMemory,
    UnsupportedVertexLayout,
};

pub const CreateMeshError = error{
    OutOfMemory,
    OutOfMeshes,
};

pub const CreateTextureError = error{
    OutOfMemory,
    GfxInitFailed,
    InvalidTextureSize,
    UnsupportedTextureSize,
    TextureDataTooSmall,
    OutOfTextures,
    OutOfTextureSlots,
    TextureCreateFailed,
    PendingTextureQueueFull,
};

/// Required declarations on the selected graphics backend.
pub const Interface = struct {
    mesh_source_mode: Mesh.SourceMode,

    setup: fn (std.mem.Allocator, std.Io) void,
    init: fn () InitError!void,
    deinit: fn () void,

    /// Resource handles are resolved by the caller; backends own no default assets.
    set_render_state: fn (*const RenderState) void,

    start_frame: fn () bool,
    end_frame: fn () void,
    clear_depth: fn () void,
    has_second_screen: fn () bool,
    switch_second_screen: fn () void,

    set_vsync: fn (bool) void,

    create_mesh: fn (*const Mesh.Desc) CreateMeshError!Mesh.Handle,
    destroy_mesh: fn (Mesh.Handle) void,
    update_mesh: fn (Mesh.Handle, *const Mesh.UpdateDesc) void,
    draw_mesh: fn (Mesh.Handle, *const Mat4) void,

    create_texture: fn (*const Texture.UploadDesc) CreateTextureError!Texture.Handle,
    update_texture: fn (Texture.Handle, []align(16) u8) void,
    destroy_texture: fn (Texture.Handle) void,
    force_texture_resident: fn (Texture.Handle) void,
};

pub fn assert_impl(comptime Backend: type) void {
    @import("contract.zig").assert_impl("gfx", Backend, Interface);
}
