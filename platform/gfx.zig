//! Graphics backend contract, the selected backend, and frame-level state.
const std = @import("std");
const backend = @import("backend.zig");
const surface_contract = @import("surface.zig");
const contract = @import("contract.zig");
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
    contract.assert_impl("gfx", Backend, Interface);
}

/// Selected graphics backend (`headless/` for headless builds).
pub const Api = backend.gfx;
/// CPU-side texture layout expected by the selected backend.
pub const texture_pixels = backend.texture_pixels;
pub const Surface = surface_contract.Surface;

comptime {
    assert_impl(Api);
}

pub const api = Api;
pub var surface: Surface = undefined;
pub var sync: bool = true;
pub var frame_active: bool = false;

pub fn init(
    alloc: std.mem.Allocator,
    io: std.Io,
    width: u32,
    height: u32,
    title: [:0]const u8,
    fullscreen: bool,
    vsync: bool,
    resizable: bool,
) InitError!void {
    sync = vsync;
    surface = .{ .alloc = alloc };
    try surface.init(width, height, title, fullscreen, vsync, resizable);
    errdefer surface.deinit();

    Api.setup(alloc, io);
    try Api.init();
}

pub fn deinit() void {
    Api.deinit();
    surface.deinit();
}

pub fn set_vsync(v: bool) void {
    sync = v;
    Api.set_vsync(v);
}

/// Ensure a backend that borrows CPU mesh memory has finished consuming the
/// previous frame before game code mutates or frees that memory.
pub inline fn wait_for_borrowed_meshes() void {
    if (comptime @hasDecl(Api, "wait_for_borrowed_meshes")) {
        Api.wait_for_borrowed_meshes();
    }
}

pub const has_second_screen = Api.has_second_screen;
pub const switch_second_screen = Api.switch_second_screen;
