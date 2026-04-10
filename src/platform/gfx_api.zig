const Mat4 = @import("../math/math.zig").Mat4;
const Util = @import("../util/util.zig");
const Rendering = @import("../rendering/rendering.zig");
const Mesh = Rendering.mesh;
const Pipeline = Rendering.Pipeline;
const Texture = Rendering.Texture;

const Self = @This();

ptr: *anyopaque,
tab: *const VTable,

pub const VTable = struct {
    // --- API Setup / Lifecycle ---
    init: *const fn (ctx: *anyopaque) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,

    // --- API State ---
    set_clear_color: *const fn (ctx: *anyopaque, r: f32, g: f32, b: f32, a: f32) void,
    set_alpha_blend: *const fn (ctx: *anyopaque, enabled: bool) void,
    set_fog: *const fn (ctx: *anyopaque, enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void,
    set_clip_planes: *const fn (ctx: *anyopaque, enabled: bool) void,
    set_proj_matrix: *const fn (ctx: *anyopaque, mat: *const Mat4) void,
    set_view_matrix: *const fn (ctx: *anyopaque, mat: *const Mat4) void,

    // --- Frame Management ---
    start_frame: *const fn (ctx: *anyopaque) bool,
    end_frame: *const fn (ctx: *anyopaque) void,
    clear_depth: *const fn (ctx: *anyopaque) void,

    // --- Pipeline API ---
    create_pipeline: *const fn (ctx: *anyopaque, layout: Pipeline.VertexLayout, v_shader: ?[:0]align(4) const u8, f_shader: ?[:0]align(4) const u8) anyerror!Pipeline.Handle,
    destroy_pipeline: *const fn (ctx: *anyopaque, pipeline: Pipeline.Handle) void,
    bind_pipeline: *const fn (ctx: *anyopaque, pipeline: Pipeline.Handle) void,

    // --- Mesh API (raw) ---
    // These are intentionally not exposed directly to the user.
    // Use the Mesh abstraction instead.
    create_mesh: *const fn (ctx: *anyopaque, pipeline: Pipeline.Handle) anyerror!Mesh.Handle,
    destroy_mesh: *const fn (ctx: *anyopaque, mesh: Mesh.Handle) void,
    update_mesh: *const fn (ctx: *anyopaque, mesh: Mesh.Handle, data: []const u8) void,
    draw_mesh: *const fn (ctx: *anyopaque, mesh: Mesh.Handle, model: *const Mat4, count: usize, primitive: Mesh.Primitive) void,

    // --- Texture API (raw) ---
    create_texture: *const fn (ctx: *anyopaque, width: u32, height: u32, data: []align(16) u8) anyerror!Texture.Handle,
    update_texture: *const fn (ctx: *anyopaque, handle: Texture.Handle, data: []align(16) u8) void,
    bind_texture: *const fn (ctx: *anyopaque, handle: Texture.Handle) void,
    destroy_texture: *const fn (ctx: *anyopaque, handle: Texture.Handle) void,
    force_texture_resident: *const fn (ctx: *anyopaque, handle: Texture.Handle) void,
};

/// Starts the Graphics API. Must be called before any other graphics functions.
/// Returns an error if initialization fails.
pub inline fn init(self: *const Self) !void {
    try self.tab.init(self.ptr);
}

/// Shuts down the Graphics API and frees all associated resources.
/// After calling this, no other graphics functions should be called.
pub inline fn deinit(self: *const Self) void {
    self.tab.deinit(self.ptr);
}

/// Sets the color used to clear the screen each frame.
/// The color is specified as RGBA values in the range [0.0, 1.0].
/// These are automatically used when `start_frame` is called.
pub inline fn set_clear_color(self: *const Self, r: f32, g: f32, b: f32, a: f32) void {
    self.tab.set_clear_color(self.ptr, r, g, b, a);
}

/// Enables or disables alpha blending.
pub inline fn set_alpha_blend(self: *const Self, enabled: bool) void {
    self.tab.set_alpha_blend(self.ptr, enabled);
}

/// Sets linear fog parameters.
pub inline fn set_fog(self: *const Self, enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    self.tab.set_fog(self.ptr, enabled, start, end, r, g, b);
}

/// Enables or disables hardware clip planes (PSP only, no-op on desktop).
pub inline fn set_clip_planes(self: *const Self, enabled: bool) void {
    self.tab.set_clip_planes(self.ptr, enabled);
}

/// Begins a new frame. This should be called once per frame before any drawing commands.
/// Returns true if the frame was successfully started, false otherwise (e.g., if the window
/// was minimized).
pub inline fn start_frame(self: *const Self) bool {
    return self.tab.start_frame(self.ptr);
}

/// Ends the current frame and presents the rendered content to the screen.
/// This should be called once per frame after all drawing commands.
pub inline fn end_frame(self: *const Self) void {
    self.tab.end_frame(self.ptr);
}

/// Clears the depth buffer to its default value (1.0) within the current frame.
/// Useful for layered rendering where geometry in a later layer should not be
/// occluded by earlier layers (e.g. drawing a viewmodel on top of the world).
/// Must be called between `start_frame` and `end_frame`.
pub inline fn clear_depth(self: *const Self) void {
    self.tab.clear_depth(self.ptr);
}

/// Sets the projection matrix used for rendering.
/// This matrix transforms 3D coordinates into 2D screen space.
/// Typically, this is set once per frame or when the window is resized.
/// TODO: Support setting 2D orthographic projection and make sure it's used when drawing 2D elements.
pub inline fn set_proj_matrix(self: *const Self, mat: *const Mat4) void {
    self.tab.set_proj_matrix(self.ptr, mat);
}

/// Sets the view matrix used for rendering.
/// This matrix represents the camera's position and orientation in the scene.
/// It is typically updated each frame based on camera movement.
pub inline fn set_view_matrix(self: *const Self, mat: *const Mat4) void {
    self.tab.set_view_matrix(self.ptr, mat);
}

const GraphicsAPI = @import("platform.zig").GraphicsAPI;

/// Factory function to create a GraphicsAPI instance based on the specified API type.
/// This is a comptime function that selects the appropriate implementation, runtime polymorphism is avoided for performance.
pub fn make_api(comptime api: GraphicsAPI) !Self {
    const builtin = @import("builtin");
    switch (api) {
        .default => {
            if (builtin.os.tag == .psp) {
                const PspGfxGe = @import("psp/psp_gfx_ge.zig");
                var psp = try Util.allocator(.render).create(PspGfxGe);
                return psp.gfx_api();
            } else {
                @compileError("No default graphics backend for this platform");
            }
        },
        .opengl => {
            if (builtin.os.tag == .macos) @compileError("OpenGL is not supported on macOS, use Vulkan instead.");

            const OpenGLAPI = @import("glfw/opengl/opengl_gfx.zig");
            var opengl = try Util.allocator(.render).create(OpenGLAPI);
            return opengl.gfx_api();
        },
        .vulkan => {
            const VulkanAPI = @import("glfw/vulkan/vulkan_gfx.zig");
            var vulkan = try Util.allocator(.render).create(VulkanAPI);
            return vulkan.gfx_api();
        },
        .headless => {
            const HeadlessGfx = @import("headless/headless_gfx.zig");
            var headless = try Util.allocator(.render).create(HeadlessGfx);
            return headless.gfx_api();
        },
    }
}
