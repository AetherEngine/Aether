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

const Swapchain = struct {
    const BUFFER_COUNT = 3;

    const State = struct {
        draw_idx: u2 = 0,
        display_idx: u2 = 0,
        ready_display: ?u2 = null,
        ready_queue: [BUFFER_COUNT]u2 = .{ 0, 0, 0 },
        ready_count: u2 = 0,
    };

    display_list: [0x10000]u32 align(16) = [_]u32{0} ** 0x10000,
    buffers_rel: [BUFFER_COUNT]?*anyopaque = .{ null, null, null },
    buffers_abs: [BUFFER_COUNT]?*anyopaque = .{ null, null, null },
    state_storage: State = .{},

    fn state(self: *Swapchain) *volatile State {
        return @ptrCast(&self.state_storage);
    }

    fn init(self: *Swapchain) void {
        const vram_base = @intFromPtr(ge.edram_get_addr());
        const uncached: usize = 0x40000000;

        self.state().display_idx = 0;
        self.state().draw_idx = 1;
        self.state().ready_count = 0;
        self.state().ready_display = null;

        for (0..BUFFER_COUNT) |i| {
            self.buffers_rel[i] = sdk.extra.vram.allocVramRelative(SCR_BUF_WIDTH, SCREEN_HEIGHT, gu_pixel_format);
            self.buffers_abs[i] = @ptrFromInt(@intFromPtr(self.buffers_rel[i]) + vram_base | uncached);
        }
    }

    fn next_draw_idx(self: *Swapchain) u2 {
        const s = self.state();
        const cur_display = s.display_idx;
        const cur_ready = s.ready_display;

        for (0..BUFFER_COUNT) |i| {
            const idx: u2 = @intCast(i);
            if (idx == cur_display) continue;
            if (cur_ready != null and idx == cur_ready.?) continue;
            return idx;
        }
        return s.draw_idx;
    }

    fn push_ready(self: *Swapchain, idx: u2) void {
        const s = self.state();
        if (s.ready_count < BUFFER_COUNT) {
            s.ready_queue[s.ready_count] = idx;
            s.ready_count += 1;
        }
    }

    fn pop_ready(self: *Swapchain) ?u2 {
        const s = self.state();
        if (s.ready_count > 0) {
            const disp = s.ready_queue[0];
            var i: u2 = 0;
            while (i < s.ready_count - 1) : (i += 1) {
                s.ready_queue[i] = s.ready_queue[i + 1];
            }
            s.ready_count -= 1;
            return disp;
        }
        return null;
    }

    fn ge_finish_callback(_: c_int) void {
        const intr = kernel.cpu_suspend_intr();
        defer kernel.cpu_resume_intr_with_sync(intr);

        if (swapchain.pop_ready()) |disp| {
            swapchain.state().ready_display = disp;
        }
    }

    fn vblank_handler(_: c_int, _: c_int, _: ?*anyopaque) callconv(.c) c_int {
        const intr = kernel.cpu_suspend_intr();
        defer kernel.cpu_resume_intr_with_sync(intr);

        const s = swapchain.state();
        if (s.ready_display) |disp| {
            display.set_frame_buf(swapchain.buffers_abs[disp], SCR_BUF_WIDTH, display_pixel_format, .immediate) catch {};
            s.display_idx = disp;
            s.ready_display = null;
        }
        return -1;
    }
};

var swapchain: Swapchain = .{};

clear_color: u24 = 0x000000,

fn init(ctx: *anyopaque) !void {
    const self = Util.ctx_to_self(Self, ctx);
    self.clear_color = 0x000000;

    swapchain.init();
    const zbp = sdk.extra.vram.allocVramRelative(SCR_BUF_WIDTH, SCREEN_HEIGHT, .Psm4444);
    const s = swapchain.state();

    gu.init();
    _ = gu.set_callback(4, Swapchain.ge_finish_callback); // GuCallbackId.Finish = 4
    gu.start(.Direct, &swapchain.display_list);
    gu.draw_buffer(display_pixel_format, swapchain.buffers_rel[s.draw_idx], SCR_BUF_WIDTH);
    gu.disp_buffer(SCREEN_WIDTH, SCREEN_HEIGHT, swapchain.buffers_rel[s.display_idx], SCR_BUF_WIDTH);
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
    try display.set_frame_buf(swapchain.buffers_abs[s.display_idx], SCR_BUF_WIDTH, display_pixel_format, .next_vblank);

    try kernel.register_sub_intr_handler(VBLANK_INT, 0, @ptrCast(@constCast(&Swapchain.vblank_handler)), null);
    try kernel.enable_sub_intr(VBLANK_INT, 0);
}

fn deinit(_: *anyopaque) void {
    kernel.disable_sub_intr(VBLANK_INT, 0) catch {};
    kernel.release_sub_intr_handler(VBLANK_INT, 0) catch {};
    _ = gu.set_callback(4, null); // clear GE finish callback
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

    // Wait for previous frame's GE to finish before reusing the display list buffer.
    gu.sync(.List, .wait);

    gu.start(.Direct, &swapchain.display_list);
    gu.clear_color(self.clear_color);
    gu.clear_depth(1);
    gu.clear(@intFromEnum(sdk.ClearBitFlags.ColorBuffer) |
        @intFromEnum(sdk.ClearBitFlags.DepthBuffer) | @intFromEnum(sdk.ClearBitFlags.StencilBuffer));

    return true;
}

fn end_frame(_: *anyopaque) void {
    {
        const intr = kernel.cpu_suspend_intr();
        defer kernel.cpu_resume_intr_with_sync(intr);

        const s = swapchain.state();

        // Push current draw buffer to ready queue BEFORE gu.finish(),
        // since the GE finish callback may fire immediately after finish.
        swapchain.push_ready(s.draw_idx);

        // Pick the next free buffer.
        s.draw_idx = swapchain.next_draw_idx();
    }

    gu.finish();

    gu.draw_buffer(display_pixel_format, swapchain.buffers_rel[swapchain.state().draw_idx], SCR_BUF_WIDTH);
}

fn create_pipeline(_: *anyopaque, layout: Pipeline.VertexLayout, _: ?[:0]align(4) const u8, _: ?[:0]align(4) const u8) !Pipeline.Handle {
    var vtype = VertexType{
        .vertex = .Vertex32Bitf, // default, overridden by position attribute
        .transform = .Transform3D,
    };

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
                    else => .Texture32Bitf,
                };
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
    sdk.kernel.dcache_writeback_range(data.ptr, @intCast(data.len));

    const handle = textures.add_element(.{
        .width = width,
        .height = height,
        .data = data.ptr,
        .in_vram = false,
    }) orelse return error.OutOfTextures;

    return @intCast(handle);
}

fn update_texture(_: *anyopaque, handle: Texture.Handle, data: []const u8) void {
    var tex = textures.get_element(handle) orelse return;
    tex.data = data.ptr;
    sdk.kernel.dcache_writeback_range(data.ptr, @intCast(data.len));
    textures.update_element(handle, tex);
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
