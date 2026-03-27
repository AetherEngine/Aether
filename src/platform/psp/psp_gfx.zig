const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const GFXAPI = @import("../gfx_api.zig");
const gfx = @import("../gfx.zig");

const sdk = @import("pspsdk");
const gu = sdk.gu;
const gum = sdk.gum;

const SCREEN_WIDTH = sdk.extra.constants.SCREEN_WIDTH;
const SCREEN_HEIGHT = sdk.extra.constants.SCREEN_HEIGHT;
const SCR_BUF_WIDTH = sdk.extra.constants.SCR_BUF_WIDTH;

const options = @import("options");
const display_pixel_format: sdk.display.PixelFormat = switch (options.config.psp_display_mode) {
    .rgba8888 => .rgba8888,
    .rgb565 => .rgb565,
};
const gu_pixel_format: gu.types.GuPixelFormat = switch (options.config.psp_display_mode) {
    .rgba8888 => .Psm8888,
    .rgb565 => .Psm5650,
};

const display = sdk.display;
const kernel = sdk.kernel;
const ge = sdk.ge;

const VBLANK_INT = 30;

const VertexType = sdk.VertexType;

const PipelineData = struct {
    vertex_type: VertexType,
    stride: usize,
};

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var bound_pipeline: Pipeline.Handle = 0;

const Self = @This();

var display_list: [0x10000]u32 align(16) = [_]u32{0} ** 0x10000;

// Triple buffer: 3 buffers with relative (for GU) and absolute (for set_frame_buf) addresses.
// At any time: one is being drawn to, one is ready (finished), one is being displayed.
var buffers_rel: [3]?*anyopaque = .{ null, null, null };
var buffers_abs: [3]?*anyopaque = .{ null, null, null };
var draw_idx: u2 = 0; // buffer GU is rendering into
var pending_idx: ?u2 = null; // buffer GE is finishing, not yet safe to display
var ready_idx: ?u2 = null; // buffer finished rendering, waiting for display
var display_idx: u2 = 0; // buffer currently shown by LCD

fn vblank_handler(_: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
    if (ready_idx) |ri| {
        // Show the ready buffer
        display.set_frame_buf(buffers_abs[ri], SCR_BUF_WIDTH, display_pixel_format, .immediate) catch {};
        display_idx = ri;
        ready_idx = null;
    }
    return -1;
}

clear_color: u24 = 0x000000,

fn init(ctx: *anyopaque) !void {
    const self = Util.ctx_to_self(Self, ctx);
    self.clear_color = 0xFFFFFF;

    const vram_base = @intFromPtr(ge.edram_get_addr());
    const uncached: usize = 0x40000000;

    // Display buffer first so it gets VRAM offset 0 (avoids null relative pointer issue)
    display_idx = 0;
    draw_idx = 1;
    ready_idx = null;

    for (0..3) |i| {
        buffers_rel[i] = sdk.extra.vram.allocVramRelative(SCR_BUF_WIDTH, SCREEN_HEIGHT, gu_pixel_format);
        buffers_abs[i] = @ptrFromInt(@intFromPtr(buffers_rel[i]) + vram_base | uncached);
    }
    const zbp = sdk.extra.vram.allocVramRelative(SCR_BUF_WIDTH, SCREEN_HEIGHT, .Psm4444);

    gu.init();
    gu.start(.Direct, &display_list);
    gu.draw_buffer(display_pixel_format, buffers_rel[draw_idx], SCR_BUF_WIDTH);
    gu.disp_buffer(SCREEN_WIDTH, SCREEN_HEIGHT, buffers_rel[display_idx], SCR_BUF_WIDTH);
    gu.depth_buffer(zbp, SCR_BUF_WIDTH);
    gu.offset(2048 - (SCREEN_WIDTH / 2), 2048 - (SCREEN_HEIGHT / 2));
    gu.viewport(2048, 2048, SCREEN_WIDTH, SCREEN_HEIGHT);
    gu.depth_range(65535, 0);
    gu.scissor(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT);
    gu.enable(.ScissorTest);
    gu.depth_func(.GreaterOrEqual);
    gu.enable(.DepthTest);
    gu.shade_model(.Smooth);
    gu.front_face(.CounterClockwise);
    gu.enable(.CullFace);
    gu.disable(.ClipPlanes);
    gu.enable(.Texture2D);

    // Initialize all matrix modes to identity so hardware registers are never garbage.
    gum.matrix_mode(.Projection);
    gum.load_identity();
    gum.matrix_mode(.View);
    gum.load_identity();
    gum.matrix_mode(.Model);
    gum.load_identity();
    gum.matrix_mode(.Texture);
    gum.load_identity();
    gum.update_matrix();

    gu.finish();
    gu.sync(.Finish, .wait);

    try display.wait_vblank_start();
    gu.display(false);

    // Set frame buf AFTER gu.display(false), since gu.display(false)
    // internally calls sceDisplaySetFrameBuf(NULL) and would override us.
    try display.set_frame_buf(buffers_abs[display_idx], SCR_BUF_WIDTH, display_pixel_format, .next_vblank);

    try kernel.register_sub_intr_handler(VBLANK_INT, 0, @ptrCast(@constCast(&vblank_handler)), null);
    try kernel.enable_sub_intr(VBLANK_INT, 0);
}

fn deinit(_: *anyopaque) void {
    kernel.disable_sub_intr(VBLANK_INT, 0) catch {};
    kernel.release_sub_intr_handler(VBLANK_INT, 0) catch {};
    gu.term();
}

fn set_clear_color(ctx: *anyopaque, r: f32, g: f32, b: f32, _: f32) void {
    const self = Util.ctx_to_self(Self, ctx);
    const ri: u8 = @intFromFloat(@max(0.0, @min(1.0, r)) * 255.0);
    const gi: u8 = @intFromFloat(@max(0.0, @min(1.0, g)) * 255.0);
    const bi: u8 = @intFromFloat(@max(0.0, @min(1.0, b)) * 255.0);
    self.clear_color = @as(u24, bi) << 16 | @as(u24, gi) << 8 | ri;
}

const ScePspFMatrix4 = sdk.c.types.ScePspFMatrix4;

fn to_psp_matrix(mat: *const Mat4) *const ScePspFMatrix4 {
    return @ptrCast(&mat.data);
}

fn set_proj_matrix(_: *anyopaque, mat: *const Mat4) void {
    gum.matrix_mode(.Projection);
    gum.load_matrix(to_psp_matrix(mat));
}

fn set_view_matrix(_: *anyopaque, mat: *const Mat4) void {
    gum.matrix_mode(.View);
    gum.load_matrix(to_psp_matrix(mat));
}

fn start_frame(ctx: *anyopaque) bool {
    const self = Util.ctx_to_self(Self, ctx);

    // Wait for previous frame's GE to finish, then promote pending → ready.
    // The sync should be near-instant since CPU did update/tick in between.
    if (pending_idx) |pi| {
        gu.sync(.Finish, .wait);
        ready_idx = pi;
        pending_idx = null;
    }

    gu.start(.Direct, &display_list);
    gu.clear_color(self.clear_color);
    gu.clear_depth(1);
    gu.clear(@intFromEnum(sdk.ClearBitFlags.ColorBuffer) |
        @intFromEnum(sdk.ClearBitFlags.DepthBuffer) | @intFromEnum(sdk.ClearBitFlags.StencilBuffer));

    return true;
}

fn next_draw_idx() u2 {
    // Snapshot volatile state to avoid race with vblank handler
    const cur_display = display_idx;
    const cur_ready = ready_idx;

    // Pick a buffer that's not being displayed and not ready
    for (0..3) |i| {
        const idx: u2 = @intCast(i);
        if (idx != cur_display and (cur_ready == null or idx != cur_ready.?)) return idx;
    }
    // All busy — reuse the ready buffer (drops a frame)
    return cur_ready orelse draw_idx;
}

fn end_frame(_: *anyopaque) void {
    gu.finish();

    // Don't sync — let the GE finish asynchronously while CPU does update/tick.
    // Mark as pending; start_frame will sync and promote to ready.
    pending_idx = draw_idx;

    // Pick the free buffer. Set it as GU's disp_buffer so that swap_buffers
    // will move it into frame_buffer (the GE draw target).
    const free = next_draw_idx();
    gu.disp_buffer(SCREEN_WIDTH, SCREEN_HEIGHT, buffers_rel[free], SCR_BUF_WIDTH);
    _ = gu.swap_buffers();
    // After swap: frame_buffer = old disp (free), disp_buffer = old frame (just rendered)
    draw_idx = free;
}

fn create_pipeline(_: *anyopaque, layout: Pipeline.VertexLayout, _: ?[:0]align(4) const u8, _: ?[:0]align(4) const u8) !Pipeline.Handle {
    var vtype = VertexType{
        .vertex = .Vertex32Bitf, // always required
        .transform = .Transform3D,
    };

    for (layout.attributes) |attr| {
        switch (attr.format) {
            .f32x3 => {
                // location 0 = position (already set above)
            },
            .unorm8x4 => {
                vtype.color = .Color8888;
            },
            .f32x2 => {
                vtype.uv = .Texture32Bitf;
            },
        }
    }

    const handle = pipelines.add_element(.{
        .vertex_type = vtype,
        .stride = layout.stride,
    }) orelse return error.OutOfPipelines;

    return @intCast(handle);
}

fn destroy_pipeline(_: *anyopaque, handle: Pipeline.Handle) void {
    _ = pipelines.remove_element(handle);
}

fn bind_pipeline(_: *anyopaque, handle: Pipeline.Handle) void {
    bound_pipeline = handle;
}
const MeshData = struct {
    pipeline: Pipeline.Handle,
    data: ?[]u8,
};

var meshes = Util.CircularBuffer(MeshData, 2048).init();

fn create_mesh(_: *anyopaque, pipeline: Pipeline.Handle) !Mesh.Handle {
    const handle = meshes.add_element(.{
        .pipeline = pipeline,
        .data = null,
    }) orelse return error.OutOfMeshes;

    return @intCast(handle);
}

fn destroy_mesh(_: *anyopaque, handle: Mesh.Handle) void {
    const mesh = meshes.get_element(handle) orelse return;
    if (mesh.data) |buf| {
        Util.allocator(.render).free(buf);
    }
    _ = meshes.remove_element(handle);
}

fn update_mesh(_: *anyopaque, handle: Mesh.Handle, data: []const u8) void {
    var mesh = meshes.get_element(handle) orelse return;

    // Reallocate if the size changed
    if (mesh.data) |buf| {
        if (buf.len != data.len) {
            Util.allocator(.render).free(buf);
            mesh.data = null;
        }
    }

    if (mesh.data == null) {
        mesh.data = Util.allocator(.render).alloc(u8, data.len) catch return;
    }

    @memcpy(mesh.data.?, data);
    sdk.kernel.dcache_writeback_range(mesh.data.?.ptr, @intCast(data.len));

    meshes.update_element(handle, mesh);
}

fn draw_mesh(_: *anyopaque, handle: Mesh.Handle, model: *const Mat4, count: usize) void {
    const mesh = meshes.get_element(handle) orelse return;
    const pl = pipelines.get_element(mesh.pipeline) orelse return;
    const buf = mesh.data orelse return;

    gum.matrix_mode(.Model);
    gum.load_matrix(to_psp_matrix(model));

    gum.draw_array(
        .Triangles,
        pl.vertex_type,
        @intCast(count),
        null,
        buf.ptr,
    );
}
const TextureData = struct {
    width: u32,
    height: u32,
    data: [*]const u8,
    in_vram: bool,
};

var textures = Util.CircularBuffer(TextureData, 4096).init();
var bound_texture: Texture.Handle = 0;

fn create_texture(_: *anyopaque, width: u32, height: u32, data: []const u8) !Texture.Handle {
    const handle = textures.add_element(.{
        .width = width,
        .height = height,
        .data = data.ptr,
        .in_vram = false,
    }) orelse return error.OutOfTextures;

    return @intCast(handle);
}

fn bind_texture(_: *anyopaque, handle: Texture.Handle) void {
    bound_texture = handle;
    const tex = textures.get_element(handle) orelse return;

    gu.tex_mode(.Psm8888, 0, .Single, .Linear);
    gu.tex_image(
        0,
        @intCast(tex.width),
        @intCast(tex.height),
        @intCast(tex.width),
        @ptrCast(@alignCast(tex.data)),
    );
    gu.tex_func(.Modulate, .Rgba);
    gu.tex_filter(.Nearest, .Nearest);
    gu.tex_scale(1.0, 1.0);
    gu.tex_offset(0.0, 0.0);
}

fn destroy_texture(_: *anyopaque, handle: Texture.Handle) void {
    // VRAM allocations are static and cannot be freed individually.
    _ = textures.remove_element(handle);
}

fn force_texture_resident(_: *anyopaque, handle: Texture.Handle) void {
    var tex = textures.get_element(handle) orelse return;
    if (tex.in_vram) return;

    const size = tex.width * tex.height * 4; // RGBA8888
    const vram_ptr = sdk.extra.vram.allocVramAbsolute(
        tex.width,
        tex.height,
        .Psm8888,
    ) orelse @panic("force_texture_resident: VRAM allocation failed");

    const dst: [*]u8 = @ptrCast(vram_ptr);
    @memcpy(dst[0..size], tex.data[0..size]);

    tex.data = dst;
    tex.in_vram = true;
    textures.update_element(handle, tex);
}

pub fn gfx_api(self: *Self) GFXAPI {
    return GFXAPI{
        .ptr = self,
        .tab = &.{
            .init = init,
            .deinit = deinit,
            .set_clear_color = set_clear_color,
            .start_frame = start_frame,
            .end_frame = end_frame,
            .set_proj_matrix = set_proj_matrix,
            .set_view_matrix = set_view_matrix,
            .create_mesh = create_mesh,
            .destroy_mesh = destroy_mesh,
            .update_mesh = update_mesh,
            .draw_mesh = draw_mesh,
            .create_texture = create_texture,
            .bind_texture = bind_texture,
            .destroy_texture = destroy_texture,
            .force_texture_resident = force_texture_resident,
            .create_pipeline = create_pipeline,
            .destroy_pipeline = destroy_pipeline,
            .bind_pipeline = bind_pipeline,
        },
    };
}
