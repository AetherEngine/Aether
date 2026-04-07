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

const tex_pixel_format: gu.types.GuPixelFormat = switch (options.config.psp_display_mode) {
    .rgba8888 => .Psm8888,
    .rgb565 => .Psm4444,
};
const tex_bpp: u32 = switch (options.config.psp_display_mode) {
    .rgba8888 => 4,
    .rgb565 => 2,
};

const display = sdk.display;
const ge = sdk.ge;

const VertexType = sdk.VertexType;

const PipelineData = struct {
    vertex_type: VertexType,
    stride: usize,
    // When UVs are unorm8x2, raw u8 bytes are reinterpreted by the GE as
    // signed 8-bit texcoords. To remap [0,255] back to [0,1] we apply
    // sceGuTexOffset(1.0, 1.0) and sceGuTexScale(0.5, 0.5) before drawing.
    uv_unorm8: bool,
};

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var bound_pipeline: Pipeline.Handle = 0;
var alpha_blend_enabled: bool = true;

const Self = @This();

const Swapchain = struct {
    const BUFFER_COUNT = 2;

    display_list: [0x10000]u32 align(16) = [_]u32{0} ** 0x10000,
    buffers_rel: [BUFFER_COUNT]?*anyopaque = .{ null, null },
    buffers_abs: [BUFFER_COUNT]?*anyopaque = .{ null, null },
    draw_idx: u1 = 1,
    display_idx: u1 = 0,

    fn init(self: *Swapchain) void {
        const vram_base = @intFromPtr(ge.edram_get_addr());
        const uncached: usize = 0x40000000;

        self.display_idx = 0;
        self.draw_idx = 1;

        for (0..BUFFER_COUNT) |i| {
            self.buffers_rel[i] = sdk.extra.vram.allocVramRelative(SCR_BUF_WIDTH, SCREEN_HEIGHT, gu_pixel_format);
            self.buffers_abs[i] = @ptrFromInt(@intFromPtr(self.buffers_rel[i]) + vram_base | uncached);
        }
    }

    fn swap(self: *Swapchain) void {
        self.draw_idx = ~self.draw_idx;
        self.display_idx = ~self.display_idx;
    }
};

var swapchain: Swapchain = .{};

clear_color: u24 = 0x000000,

fn init(ctx: *anyopaque) !void {
    const self = Util.ctx_to_self(Self, ctx);
    self.clear_color = 0x000000;

    swapchain.init();
    const zbp = sdk.extra.vram.allocVramRelative(SCR_BUF_WIDTH, SCREEN_HEIGHT, .Psm4444);

    gu.init();
    gu.start(.Direct, &swapchain.display_list);
    gu.draw_buffer(display_pixel_format, swapchain.buffers_rel[swapchain.draw_idx], SCR_BUF_WIDTH);
    gu.disp_buffer(SCREEN_WIDTH, SCREEN_HEIGHT, swapchain.buffers_rel[swapchain.display_idx], SCR_BUF_WIDTH);
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
    gu.enable(.AlphaTest);
    gu.alpha_func(.Greater, 16, 0xFF);
    gu.enable(.Blend);
    gu.blend_func(.Add, .SrcAlpha, .OneMinusSrcAlpha, 0, 0);
    gu.enable(.Texture2D);
    gu.tex_scale(1.0, 1.0);
    gu.tex_offset(0.0, 0.0);

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
    try display.set_frame_buf(swapchain.buffers_abs[swapchain.display_idx], SCR_BUF_WIDTH, display_pixel_format, .next_vblank);
}

fn deinit(_: *anyopaque) void {
    gu.term();
}

fn set_alpha_blend(_: *anyopaque, enabled: bool) void {
    if (enabled == alpha_blend_enabled) return;
    alpha_blend_enabled = enabled;
    if (enabled) {
        gu.enable(.Blend);
        gu.enable(.AlphaTest);
    } else {
        gu.disable(.Blend);
        gu.disable(.AlphaTest);
    }
}

var clip_planes_enabled: bool = false;

fn set_clip_planes(_: *anyopaque, enabled: bool) void {
    if (enabled == clip_planes_enabled) return;
    clip_planes_enabled = enabled;
    if (enabled) gu.enable(.ClipPlanes) else gu.disable(.ClipPlanes);
}

var fog_enabled: bool = false;

fn set_fog(_: *anyopaque, enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    if (enabled) {
        const ri: u32 = @intFromFloat(@max(0.0, @min(1.0, r)) * 255.0);
        const gi: u32 = @intFromFloat(@max(0.0, @min(1.0, g)) * 255.0);
        const bi: u32 = @intFromFloat(@max(0.0, @min(1.0, b)) * 255.0);
        const color: c_uint = @intCast(bi << 16 | gi << 8 | ri);
        gu.fog(start, end, color);
        if (!fog_enabled) {
            gu.enable(.Fog);
            fog_enabled = true;
        }
    } else {
        if (fog_enabled) {
            gu.disable(.Fog);
            fog_enabled = false;
        }
    }
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

    gu.sync(.Finish, .wait);
    display.set_frame_buf(swapchain.buffers_abs[swapchain.draw_idx], SCR_BUF_WIDTH, display_pixel_format, .immediate) catch {};
    swapchain.swap();
    gu.draw_buffer(display_pixel_format, swapchain.buffers_rel[swapchain.draw_idx], SCR_BUF_WIDTH);

    gu.start(.Direct, &swapchain.display_list);
    gu.clear_color(self.clear_color);
    gu.clear_depth(1);
    gu.clear(.{ .color = true, .depth = true, .stencil = true });

    return true;
}

fn clear_depth(_: *anyopaque) void {
    gu.clear_depth(1);
    gu.clear(.{ .depth = true });
}

fn end_frame(_: *anyopaque) void {
    gu.finish();
    // gu.sync(.Finish, .wait);

    // display.wait_vblank_start() catch {};
    // display.set_frame_buf(swapchain.buffers_abs[swapchain.draw_idx], SCR_BUF_WIDTH, display_pixel_format, .immediate) catch {};

    // swapchain.swap();
    // gu.draw_buffer(display_pixel_format, swapchain.buffers_rel[swapchain.draw_idx], SCR_BUF_WIDTH);
}

fn create_pipeline(_: *anyopaque, layout: Pipeline.VertexLayout, _: ?[:0]align(4) const u8, _: ?[:0]align(4) const u8) !Pipeline.Handle {
    var vtype = VertexType{
        .vertex = .Vertex32Bitf, // default, overridden by position attribute
        .transform = .Transform3D,
    };
    var uv_unorm8 = false;

    for (layout.attributes) |attr| {
        switch (attr.usage) {
            .position => {
                vtype.vertex = switch (attr.format) {
                    .f32x3 => .Vertex32Bitf,
                    .unorm16x3, .snorm16x3 => .Vertex16Bit,
                    else => .Vertex32Bitf,
                };
            },
            .uv => {
                vtype.uv = switch (attr.format) {
                    .f32x2 => .Texture32Bitf,
                    .unorm16x2, .snorm16x2 => .Texture16Bit,
                    .unorm8x2 => .Texture8Bit,
                    else => .Texture32Bitf,
                };
                uv_unorm8 = attr.format == .unorm8x2;
            },
            .color => {
                vtype.color = .Color8888;
            },
            .normal => {
                vtype.normal = switch (attr.format) {
                    .f32x3 => .Normal32Bitf,
                    .unorm16x3, .snorm16x3 => .Normal16Bit,
                    else => .Normal32Bitf,
                };
            },
        }
    }

    const handle = pipelines.add_element(.{
        .vertex_type = vtype,
        .stride = layout.stride,
        .uv_unorm8 = uv_unorm8,
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
    data: ?[*]const u8,
    len: usize,
};

var meshes = Util.CircularBuffer(MeshData, 2048).init();

fn create_mesh(_: *anyopaque, pipeline: Pipeline.Handle) !Mesh.Handle {
    const handle = meshes.add_element(.{
        .pipeline = pipeline,
        .data = null,
        .len = 0,
    }) orelse return error.OutOfMeshes;

    return @intCast(handle);
}

fn destroy_mesh(_: *anyopaque, handle: Mesh.Handle) void {
    _ = meshes.remove_element(handle);
}

fn update_mesh(_: *anyopaque, handle: Mesh.Handle, data: []const u8) void {
    var mesh = meshes.get_element(handle) orelse return;

    mesh.data = data.ptr;
    mesh.len = data.len;
    sdk.kernel.dcache_writeback_range(data.ptr, @intCast(data.len));

    meshes.update_element(handle, mesh);
}

fn draw_mesh(_: *anyopaque, handle: Mesh.Handle, model: *const Mat4, count: usize, primitive: Mesh.Primitive) void {
    const mesh = meshes.get_element(handle) orelse return;
    const pl = pipelines.get_element(mesh.pipeline) orelse return;
    const data = mesh.data orelse return;

    gum.matrix_mode(.Model);
    gum.load_matrix(to_psp_matrix(model));

    if (pl.uv_unorm8) {
        gu.tex_offset(1.0, 1.0);
        gu.tex_scale(0.5, 0.5);
    } else {
        gu.tex_offset(0.0, 0.0);
        gu.tex_scale(1.0, 1.0);
    }

    gum.draw_array(
        switch (primitive) {
            .triangles => .Triangles,
            .lines => .Lines,
        },
        pl.vertex_type,
        @intCast(count),
        null,
        data,
    );
}
const TextureData = struct {
    width: u32,
    height: u32,
    // Pointer actually bound to the GE. Equals cpu_data until the texture is
    // made VRAM-resident, after which it points at the VRAM copy.
    data: [*]const u8,
    // The caller's RAM buffer (Rendering.Texture.data.ptr). Always valid and
    // always in the correct (swizzled or linear) layout, since set_pixel
    // routes writes through pixel_offset.
    cpu_data: [*]align(16) u8,
    in_vram: bool,
    swizzled: bool,
};

fn swizzle_in_place(data: []align(16) u8, width: u32, height: u32) void {
    const width_bytes = width * tex_bpp;
    if (width_bytes * height < 8 * 1024) return;

    const alloc = Util.allocator(.render);
    const tmp = alloc.alignedAlloc(u8, .fromByteUnits(16), data.len) catch return;
    defer alloc.free(tmp);

    @memcpy(tmp, data);

    const width_blocks = width_bytes / 16;
    const height_blocks = height / 8;
    const src_pitch = (width_bytes - 16) / 4;
    const src_row = width_bytes * 8;

    var dst: [*]u32 = @ptrCast(@alignCast(data.ptr));
    var ysrc: [*]const u8 = tmp.ptr;

    for (0..height_blocks) |_| {
        var xsrc = ysrc;
        for (0..width_blocks) |_| {
            var src: [*]const u32 = @ptrCast(@alignCast(xsrc));
            for (0..8) |_| {
                dst[0] = src[0];
                dst[1] = src[1];
                dst[2] = src[2];
                dst[3] = src[3];
                dst += 4;
                src += 4 + src_pitch;
            }
            xsrc += 16;
        }
        ysrc += src_row;
    }
}

/// Map a linear (x, y) pixel coordinate to its byte offset in swizzled layout.
pub fn swizzled_offset(x: u32, y: u32, width: u32) usize {
    const bytes_per_pixel = tex_bpp;
    const width_bytes = width * bytes_per_pixel;

    const block_x = (x * bytes_per_pixel) / 16;
    const block_y = y / 8;
    const blocks_per_row = width_bytes / 16;

    const block_index = block_y * blocks_per_row + block_x;
    const block_start = block_index * 16 * 8; // each block is 16 bytes * 8 rows

    const local_x = (x * bytes_per_pixel) % 16;
    const local_y = y % 8;

    return block_start + local_y * 16 + local_x;
}

var textures = Util.CircularBuffer(TextureData, 4096).init();
var bound_texture: Texture.Handle = 0;

fn create_texture(_: *anyopaque, width: u32, height: u32, data: []align(16) u8) !Texture.Handle {
    const width_bytes = width * tex_bpp;
    const should_swizzle = width_bytes * height >= 8 * 1024;

    if (should_swizzle) {
        swizzle_in_place(data, width, height);
    }

    sdk.kernel.dcache_writeback_range(data.ptr, @intCast(data.len));

    const handle = textures.add_element(.{
        .width = width,
        .height = height,
        .data = data.ptr,
        .cpu_data = data.ptr,
        .in_vram = false,
        .swizzled = should_swizzle,
    }) orelse return error.OutOfTextures;

    return @intCast(handle);
}

// The incoming `data` slice is the caller's RAM buffer and is already in the
// correct (swizzled or linear) layout thanks to Rendering.Texture.set_pixel
// routing writes through pixel_offset. We must NOT swizzle again here.
fn update_texture(_: *anyopaque, handle: Texture.Handle, data: []align(16) u8) void {
    const tex = textures.get_element(handle) orelse return;

    if (tex.in_vram) {
        // The GE is sampling from VRAM; mirror the RAM buffer over it.
        const size = tex.width * tex.height * tex_bpp;
        const dst: [*]u8 = @constCast(tex.data);
        @memcpy(dst[0..size], data[0..size]);
        sdk.kernel.dcache_writeback_range(dst, @intCast(size));
    } else {
        // The RAM buffer is the GE-visible buffer; just flush dcache.
        sdk.kernel.dcache_writeback_range(data.ptr, @intCast(data.len));
    }
}

fn bind_texture(_: *anyopaque, handle: Texture.Handle) void {
    bound_texture = handle;
    const tex = textures.get_element(handle) orelse return;

    gu.tex_mode(tex_pixel_format, 0, .Single, if (tex.swizzled) .Swizzled else .Linear);
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

    const size = tex.width * tex.height * tex_bpp;
    const vram_ptr = sdk.extra.vram.allocVramAbsolute(
        tex.width,
        tex.height,
        tex_pixel_format,
    ) orelse @panic("force_texture_resident: VRAM allocation failed");

    const dst: [*]u8 = @ptrCast(vram_ptr);
    @memcpy(dst[0..size], tex.data[0..size]);

    // Only the GE-facing pointer moves to VRAM; cpu_data keeps pointing at
    // the caller's RAM buffer so update_texture can continue to mirror edits.
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
            .set_alpha_blend = set_alpha_blend,
            .set_fog = set_fog,
            .set_clip_planes = set_clip_planes,
            .start_frame = start_frame,
            .end_frame = end_frame,
            .clear_depth = clear_depth,
            .set_proj_matrix = set_proj_matrix,
            .set_view_matrix = set_view_matrix,
            .create_mesh = create_mesh,
            .destroy_mesh = destroy_mesh,
            .update_mesh = update_mesh,
            .draw_mesh = draw_mesh,
            .create_texture = create_texture,
            .update_texture = update_texture,
            .bind_texture = bind_texture,
            .destroy_texture = destroy_texture,
            .force_texture_resident = force_texture_resident,
            .create_pipeline = create_pipeline,
            .destroy_pipeline = destroy_pipeline,
            .bind_pipeline = bind_pipeline,
        },
    };
}
