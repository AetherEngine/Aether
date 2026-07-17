const std = @import("std");
const Mat4 = @import("../math/math.zig").Mat4;
const Rendering = @import("../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const RenderState = Rendering.RenderState;

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

/// The contract every graphics backend must satisfy. Each field names a
/// public top-level fn on the backend module and gives its exact type.
/// This struct is never instantiated -- it exists purely to drive
/// `assertImpl` at comptime, replacing the runtime vtable that used to
/// hold function pointers here.
pub const Interface = struct {
    mesh_source_mode: Mesh.SourceMode,

    setup: fn (std.mem.Allocator, std.Io) void,
    init: fn () InitError!void,
    deinit: fn () void,

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

/// Verify at comptime that `Backend` exposes every decl in `Interface`
/// with the exact expected signature. Fires a clean compile error at the
/// call site if a backend's method set drifts.
pub fn assert_impl(comptime Backend: type) void {
    inline for (std.meta.fields(Interface)) |f| {
        if (!@hasDecl(Backend, f.name)) {
            @compileError("gfx backend " ++ @typeName(Backend) ++ " is missing decl: " ++ f.name);
        }
        const Actual = @TypeOf(@field(Backend, f.name));
        if (Actual != f.type) {
            @compileError("gfx backend " ++ @typeName(Backend) ++ "." ++ f.name ++
                " has type " ++ @typeName(Actual) ++ ", expected " ++ @typeName(f.type));
        }
    }
}
