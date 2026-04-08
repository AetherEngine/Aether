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
const vram = @import("vram.zig");

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
            self.buffers_rel[i] = vram.alloc_relative(SCR_BUF_WIDTH, SCREEN_HEIGHT, gu_pixel_format);
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
    const zbp = vram.alloc_relative(SCR_BUF_WIDTH, SCREEN_HEIGHT, .Psm4444);

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
/// Number of mip levels generated below the base level when a texture is
/// forced VRAM-resident. The base counts as level 0; mip 1 is half-size and
/// mip 2 is quarter-size.
const MAX_MIP_LEVELS: u8 = 2;

const MipLevel = struct {
    width: u32,
    height: u32,
    data: [*]const u8,
};

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
    vram_data: ?[]align(16) u8,
    in_vram: bool,
    swizzled: bool,
    mip_count: u8,
    mips: [MAX_MIP_LEVELS]MipLevel,
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
        .vram_data = null,
        .in_vram = false,
        .swizzled = should_swizzle,
        .mip_count = 0,
        .mips = undefined,
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
        const dst = tex.vram_data orelse @panic("psp_gfx: VRAM texture missing backing slice");
        @memcpy(dst[0..size], data[0..size]);
        sdk.kernel.dcache_writeback_range(dst.ptr, @intCast(size));
    } else {
        // The RAM buffer is the GE-visible buffer; just flush dcache.
        sdk.kernel.dcache_writeback_range(data.ptr, @intCast(data.len));
    }
}

fn bind_texture(_: *anyopaque, handle: Texture.Handle) void {
    bound_texture = handle;
    const tex = textures.get_element(handle) orelse return;

    gu.tex_mode(tex_pixel_format, @intCast(tex.mip_count), .Single, if (tex.swizzled) .Swizzled else .Linear);
    gu.tex_image(
        0,
        @intCast(tex.width),
        @intCast(tex.height),
        @intCast(tex.width),
        @ptrCast(@alignCast(tex.data)),
    );
    var i: u8 = 0;
    while (i < tex.mip_count) : (i += 1) {
        const mip = tex.mips[i];
        gu.tex_image(
            @intCast(i + 1),
            @intCast(mip.width),
            @intCast(mip.height),
            @intCast(mip.width),
            @ptrCast(@alignCast(mip.data)),
        );
    }
    gu.tex_func(.Modulate, .Rgba);
    if (tex.mip_count > 0) {
        gu.tex_filter(.NearestMipmapNearest, .Nearest);
    } else {
        gu.tex_filter(.Nearest, .Nearest);
    }
    gu.tex_scale(1.0, 1.0);
    gu.tex_offset(0.0, 0.0);
}

fn destroy_texture(_: *anyopaque, handle: Texture.Handle) void {
    // VRAM allocations are static and cannot be freed individually.
    _ = textures.remove_element(handle);
}

/// Whether a mip level of `(w, h)` can be stored in the swizzled layout.
/// The swizzler operates on 16-byte-wide, 8-row-tall blocks, so the level
/// dimensions must divide evenly into a whole number of blocks.
fn swizzle_dims_supported(w: u32, h: u32) bool {
    return (w * tex_bpp) % 16 == 0 and h % 8 == 0;
}

/// Walk the planned mip chain and return the number of levels that can
/// actually be generated. Stops as soon as the next level would shrink to
/// zero or violate the swizzle constraint (when the base is swizzled).
fn count_supported_mips(base_w: u32, base_h: u32, base_swizzled: bool) u8 {
    var count: u8 = 0;
    var w = base_w;
    var h = base_h;
    while (count < MAX_MIP_LEVELS) {
        const new_w = w / 2;
        const new_h = h / 2;
        if (new_w == 0 or new_h == 0) break;
        if (base_swizzled and !swizzle_dims_supported(new_w, new_h)) break;
        count += 1;
        w = new_w;
        h = new_h;
    }
    return count;
}

/// Linearize a swizzled CPU buffer into `dst` so we can read pixels with
/// straightforward (y * w + x) addressing during mip generation.
fn deswizzle_to_linear(src: [*]const u8, dst: []u8, width: u32, height: u32) void {
    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src_off = swizzled_offset(x, y, width);
            const dst_off = (@as(usize, y) * width + x) * tex_bpp;
            inline for (0..tex_bpp) |c| {
                dst[dst_off + c] = src[src_off + c];
            }
        }
    }
}

/// Swizzle a linear `src` buffer into `dst`, mirroring `swizzle_in_place`
/// but without its 8 KB short-circuit so it works on small mip levels too.
/// Caller must ensure `swizzle_dims_supported(width, height)`.
fn swizzle_linear_to(src: []align(16) const u8, dst: []align(16) u8, width: u32, height: u32) void {
    const width_bytes = width * tex_bpp;
    const width_blocks = width_bytes / 16;
    const height_blocks = height / 8;
    const src_pitch = (width_bytes - 16) / 4;
    const src_row = width_bytes * 8;

    var dst_ptr: [*]u32 = @ptrCast(@alignCast(dst.ptr));
    var ysrc: [*]const u8 = src.ptr;

    for (0..height_blocks) |_| {
        var xsrc = ysrc;
        for (0..width_blocks) |_| {
            var src_ptr: [*]const u32 = @ptrCast(@alignCast(xsrc));
            for (0..8) |_| {
                dst_ptr[0] = src_ptr[0];
                dst_ptr[1] = src_ptr[1];
                dst_ptr[2] = src_ptr[2];
                dst_ptr[3] = src_ptr[3];
                dst_ptr += 4;
                src_ptr += 4 + src_pitch;
            }
            xsrc += 16;
        }
        ysrc += src_row;
    }
}

/// 2x2 box filter from a linear `src` (`src_w` wide) into a linear `dst`
/// (`dst_w` x `dst_h`). Branches at comptime on the active pixel format.
fn box_filter_mip(src: []const u8, src_w: u32, dst: []u8, dst_w: u32, dst_h: u32) void {
    const src_stride: usize = @as(usize, src_w) * tex_bpp;
    var dy: u32 = 0;
    while (dy < dst_h) : (dy += 1) {
        var dx: u32 = 0;
        while (dx < dst_w) : (dx += 1) {
            const sx0: usize = @as(usize, dx) * 2;
            const sy0: usize = @as(usize, dy) * 2;
            const row0 = sy0 * src_stride;
            const row1 = (sy0 + 1) * src_stride;
            const p0 = row0 + sx0 * tex_bpp;
            const p1 = row0 + (sx0 + 1) * tex_bpp;
            const p2 = row1 + sx0 * tex_bpp;
            const p3 = row1 + (sx0 + 1) * tex_bpp;
            const dst_off = (@as(usize, dy) * dst_w + dx) * tex_bpp;

            switch (options.config.psp_display_mode) {
                .rgba8888 => {
                    inline for (0..4) |c| {
                        const sum: u32 = @as(u32, src[p0 + c]) + src[p1 + c] + src[p2 + c] + src[p3 + c];
                        dst[dst_off + c] = @intCast(sum >> 2);
                    }
                },
                .rgb565 => {
                    const px0: u16 = @as(u16, src[p0]) | (@as(u16, src[p0 + 1]) << 8);
                    const px1: u16 = @as(u16, src[p1]) | (@as(u16, src[p1 + 1]) << 8);
                    const px2: u16 = @as(u16, src[p2]) | (@as(u16, src[p2 + 1]) << 8);
                    const px3: u16 = @as(u16, src[p3]) | (@as(u16, src[p3 + 1]) << 8);

                    const r = (((px0 >> 0) & 0xF) + ((px1 >> 0) & 0xF) + ((px2 >> 0) & 0xF) + ((px3 >> 0) & 0xF)) >> 2;
                    const g = (((px0 >> 4) & 0xF) + ((px1 >> 4) & 0xF) + ((px2 >> 4) & 0xF) + ((px3 >> 4) & 0xF)) >> 2;
                    const b = (((px0 >> 8) & 0xF) + ((px1 >> 8) & 0xF) + ((px2 >> 8) & 0xF) + ((px3 >> 8) & 0xF)) >> 2;
                    const a = (((px0 >> 12) & 0xF) + ((px1 >> 12) & 0xF) + ((px2 >> 12) & 0xF) + ((px3 >> 12) & 0xF)) >> 2;

                    const out: u16 = @as(u16, @intCast(r)) | (@as(u16, @intCast(g)) << 4) | (@as(u16, @intCast(b)) << 8) | (@as(u16, @intCast(a)) << 12);
                    dst[dst_off] = @truncate(out);
                    dst[dst_off + 1] = @truncate(out >> 8);
                },
            }
        }
    }
}

/// Build mip levels for a freshly VRAM-resident texture and stash their
/// VRAM pointers in `tex`. We always carry a linear scratch of the previous
/// level around so the box filter sees plain (y * w + x) addressing, then
/// optionally re-swizzle when copying into VRAM so all mip levels share the
/// same data layout as the base.
fn generate_resident_mips(tex: *TextureData) void {
    const desired = count_supported_mips(tex.width, tex.height, tex.swizzled);
    if (desired == 0) return;

    const alloc = Util.allocator(.render);

    var src_w = tex.width;
    var src_h = tex.height;
    var src_linear: ?[]align(16) u8 = null;
    defer if (src_linear) |s| alloc.free(s);

    if (tex.swizzled) {
        const base_size: usize = @as(usize, src_w) * src_h * tex_bpp;
        const buf = alloc.alignedAlloc(u8, .fromByteUnits(16), base_size) catch return;
        deswizzle_to_linear(tex.cpu_data, buf, src_w, src_h);
        src_linear = buf;
    }

    var generated: u8 = 0;
    while (generated < desired) : (generated += 1) {
        const dst_w = src_w / 2;
        const dst_h = src_h / 2;
        const dst_size: usize = @as(usize, dst_w) * dst_h * tex_bpp;

        const dst_linear = alloc.alignedAlloc(u8, .fromByteUnits(16), dst_size) catch break;

        const src_buf: []const u8 = if (src_linear) |s|
            s[0 .. @as(usize, src_w) * src_h * tex_bpp]
        else
            tex.cpu_data[0 .. @as(usize, src_w) * src_h * tex_bpp];

        box_filter_mip(src_buf, src_w, dst_linear, dst_w, dst_h);

        const vram_buf = vram.alloc_absolute_slice(dst_w, dst_h, tex_pixel_format);

        if (tex.swizzled) {
            swizzle_linear_to(dst_linear, vram_buf, dst_w, dst_h);
        } else {
            @memcpy(vram_buf[0..dst_size], dst_linear);
        }
        sdk.kernel.dcache_writeback_range(vram_buf.ptr, @intCast(dst_size));

        tex.mips[generated] = .{
            .width = dst_w,
            .height = dst_h,
            .data = vram_buf.ptr,
        };

        if (src_linear) |s| alloc.free(s);
        src_linear = dst_linear;
        src_w = dst_w;
        src_h = dst_h;
    }

    tex.mip_count = generated;
}

fn force_texture_resident(_: *anyopaque, handle: Texture.Handle) void {
    var tex = textures.get_element(handle) orelse return;
    if (tex.in_vram) return;

    const size = tex.width * tex.height * tex_bpp;
    const vram_data = vram.alloc_absolute_slice(
        tex.width,
        tex.height,
        tex_pixel_format,
    );

    @memcpy(vram_data[0..size], tex.data[0..size]);

    // Only the GE-facing pointer moves to VRAM; cpu_data keeps pointing at
    // the caller's RAM buffer so update_texture can continue to mirror edits.
    tex.data = vram_data.ptr;
    tex.vram_data = vram_data;
    tex.in_vram = true;

    generate_resident_mips(&tex);

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
