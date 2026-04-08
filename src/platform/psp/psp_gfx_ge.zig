// PSP graphics backend built directly on the PSPSDK ge_list / CommandBuffer
// API instead of the higher-level gu wrapper. Functionally equivalent to
// psp_gfx.zig (same swapchain layout, same direct-mode display list, same
// VRAM-resident texture path), but the engine owns the GE display list,
// the queue id, and the stall cursor explicitly rather than going through
// gu's hidden globals.

const std = @import("std");
const Util = @import("../../util/util.zig");
const Mat4 = @import("../../math/math.zig").Mat4;
const Rendering = @import("../../rendering/rendering.zig");
const Pipeline = Rendering.Pipeline;
const Mesh = Rendering.mesh;
const Texture = Rendering.Texture;
const GFXAPI = @import("../gfx_api.zig");

const sdk = @import("pspsdk");
const ge = sdk.ge;
const ge_list = sdk.ge_list;
const display = sdk.display;
// VRAM allocator still uses GU pixel-format enums; we only import gu for
// these constants. All other state goes through the new ge_list API.
const gu_types = sdk.gu.types;

const SCREEN_WIDTH = sdk.extra.constants.SCREEN_WIDTH;
const SCREEN_HEIGHT = sdk.extra.constants.SCREEN_HEIGHT;
const SCR_BUF_WIDTH = sdk.extra.constants.SCR_BUF_WIDTH;

const options = @import("options");

// ---- pixel format mapping --------------------------------------------------

const display_pixel_format: display.PixelFormat = switch (options.config.psp_display_mode) {
    .rgba8888 => .rgba8888,
    .rgb565 => .rgb565,
};

const ge_pixel_format: ge_list.PixelFormat = switch (options.config.psp_display_mode) {
    .rgba8888 => .rgba8888,
    .rgb565 => .rgb565,
};

const vram_color_format: gu_types.GuPixelFormat = switch (options.config.psp_display_mode) {
    .rgba8888 => .Psm8888,
    .rgb565 => .Psm5650,
};

const tex_pixel_format: ge_list.TexturePixelFormat = switch (options.config.psp_display_mode) {
    .rgba8888 => .psm8888,
    .rgb565 => .psm4444,
};

const tex_bpp: u32 = switch (options.config.psp_display_mode) {
    .rgba8888 => 4,
    .rgb565 => 2,
};

const frame_bpp: u32 = switch (options.config.psp_display_mode) {
    .rgba8888 => 4,
    .rgb565 => 2,
};

const VertexType = sdk.VertexType;

// ---- pipeline cache --------------------------------------------------------

const PipelineData = struct {
    vertex_type: VertexType,
    stride: usize,
    // When UVs are unorm8x2, raw u8 bytes are reinterpreted by the GE as
    // signed 8-bit texcoords. To remap [0,255] back to [0,1] we apply
    // texture_offset(1.0, 1.0) and texture_scale(0.5, 0.5) before drawing.
    uv_unorm8: bool,
};

var pipelines = Util.CircularBuffer(PipelineData, 16).init();
var bound_pipeline: Pipeline.Handle = 0;
var alpha_blend_enabled: bool = true;
var clip_planes_enabled: bool = false;
var fog_enabled: bool = false;

const Self = @This();

// ---- swapchain -------------------------------------------------------------

const PSP_VBLANK_INT = 30;
const PSP_DISPLAY_SUBINT = 0;
const SWAPCHAIN_BUFFER_COUNT: usize = switch (options.config.psp_display_mode) {
    .rgba8888 => 2,
    .rgb565 => 3,
};

const Swapchain = struct {
    const BUFFER_COUNT = SWAPCHAIN_BUFFER_COUNT;
    const DISPLAY_LIST_WORDS = 0x10000;
    const BufferIndex = u2;

    /// Backing storage for the GE display list. Always accessed through
    /// `list_uncached` so the GE sees writes immediately and we never need
    /// to dcache-flush the list itself. This is shared across color buffers;
    /// `acquire_draw_buffer` waits for the previous GE submission to finish
    /// before allowing the list to be reused.
    display_list: [DISPLAY_LIST_WORDS]u32 align(16) = [_]u32{0} ** DISPLAY_LIST_WORDS,
    list_uncached: []u32 = &.{},

    buffers_rel: [BUFFER_COUNT]?*anyopaque = [_]?*anyopaque{null} ** BUFFER_COUNT,
    buffers_abs: [BUFFER_COUNT]?*anyopaque = [_]?*anyopaque{null} ** BUFFER_COUNT,
    depth_buffer_rel: ?*anyopaque = null,
    draw_idx: BufferIndex = 1,
    front_idx: BufferIndex = 0,
    pending_idx: ?BufferIndex = null,
    submitted_queue: [BUFFER_COUNT]BufferIndex = [_]BufferIndex{0} ** BUFFER_COUNT,
    submitted_head: usize = 0,
    submitted_count: usize = 0,
    vblank_registered: bool = false,

    fn init(self: *Swapchain) void {
        const vram_base = @intFromPtr(ge.edram_get_addr());
        const uncached: usize = 0x40000000;

        const uncached_ptr: [*]u32 = @ptrFromInt(@intFromPtr(&self.display_list) | uncached);
        self.list_uncached = uncached_ptr[0..DISPLAY_LIST_WORDS];

        self.front_idx = 0;
        self.draw_idx = 1;
        self.pending_idx = null;
        self.submitted_head = 0;
        self.submitted_count = 0;
        self.vblank_registered = false;
        self.buffers_rel = [_]?*anyopaque{null} ** BUFFER_COUNT;
        self.buffers_abs = [_]?*anyopaque{null} ** BUFFER_COUNT;

        for (0..BUFFER_COUNT) |i| {
            self.buffers_rel[i] = sdk.extra.vram.allocVramRelative(SCR_BUF_WIDTH, SCREEN_HEIGHT, vram_color_format);
            self.buffers_abs[i] = @ptrFromInt((@intFromPtr(self.buffers_rel[i]) + vram_base) | uncached);
            self.clear_buffer(@intCast(i));
        }

        self.depth_buffer_rel = sdk.extra.vram.allocVramRelative(SCR_BUF_WIDTH, SCREEN_HEIGHT, .Psm4444);
    }

    fn clear_buffer(self: *Swapchain, idx: BufferIndex) void {
        const ptr: [*]u8 = @ptrCast(self.buffers_abs[@intCast(idx)].?);
        @memset(ptr[0 .. SCR_BUF_WIDTH * SCREEN_HEIGHT * frame_bpp], 0);
    }

    fn deinit(self: *Swapchain) void {
        if (self.vblank_registered) {
            sdk.kernel.disable_sub_intr(PSP_VBLANK_INT, PSP_DISPLAY_SUBINT) catch {};
            sdk.kernel.release_sub_intr_handler(PSP_VBLANK_INT, PSP_DISPLAY_SUBINT) catch {};
            self.vblank_registered = false;
        }
    }

    fn install_vblank_handler(self: *Swapchain) !void {
        if (self.vblank_registered) return;

        sdk.kernel.register_user_space_intr_stack();
        const handler: *anyopaque = @ptrFromInt(@intFromPtr(&vblank_handler));
        try sdk.kernel.register_sub_intr_handler(PSP_VBLANK_INT, PSP_DISPLAY_SUBINT, handler, self);
        errdefer sdk.kernel.release_sub_intr_handler(PSP_VBLANK_INT, PSP_DISPLAY_SUBINT) catch {};
        try sdk.kernel.enable_sub_intr(PSP_VBLANK_INT, PSP_DISPLAY_SUBINT);
        self.vblank_registered = true;
    }

    fn prime_display(self: *Swapchain) !void {
        try display.set_frame_buf(
            self.buffers_abs[@intCast(self.front_idx)],
            SCR_BUF_WIDTH,
            display_pixel_format,
            .next_vblank,
        );
    }

    fn mark_submitted(self: *Swapchain) void {
        const flags = sdk.kernel.cpu_suspend_intr();
        if (self.submitted_count >= BUFFER_COUNT) @panic("psp_gfx_ge: submitted queue overflow");
        const tail = (self.submitted_head + self.submitted_count) % BUFFER_COUNT;
        self.submitted_queue[tail] = self.draw_idx;
        self.submitted_count += 1;
        sdk.kernel.cpu_resume_intr(flags);
    }

    fn acquire_draw_buffer(self: *Swapchain) bool {
        const flags = sdk.kernel.cpu_suspend_intr();
        defer sdk.kernel.cpu_resume_intr(flags);

        // The display list and depth buffer are shared, so only color
        // buffers are allowed to overlap display/pending ownership. Do not
        // start recording another frame until the GE has finished the last
        // submitted one.
        if (self.submitted_count > 0) return false;

        const start = (@as(usize, self.draw_idx) + 1) % BUFFER_COUNT;
        var offset: usize = 0;
        while (offset < BUFFER_COUNT) : (offset += 1) {
            const idx: BufferIndex = @intCast((start + offset) % BUFFER_COUNT);
            if (idx == self.front_idx) continue;
            if (self.pending_idx) |pending| {
                if (idx == pending) continue;
            }
            if (self.is_submitted_locked(idx)) continue;
            self.draw_idx = idx;
            return true;
        }

        // RGBA8888 cannot afford a third color buffer. If VBlank has not
        // consumed the pending frame yet, force that swap now and draw into
        // the old front buffer. This can tear, but avoids corrupting the
        // pending flip and stalling the app.
        if (BUFFER_COUNT == 2) {
            const pending = self.pending_idx orelse return false;
            const old_front = self.front_idx;
            display.set_frame_buf(
                self.buffers_abs[@intCast(pending)],
                SCR_BUF_WIDTH,
                display_pixel_format,
                .immediate,
            ) catch {};
            self.front_idx = pending;
            self.pending_idx = null;
            self.draw_idx = old_front;
            return true;
        }

        return false;
    }

    fn is_submitted_locked(self: *const Swapchain, idx: BufferIndex) bool {
        var offset: usize = 0;
        while (offset < self.submitted_count) : (offset += 1) {
            const queue_idx = (self.submitted_head + offset) % BUFFER_COUNT;
            if (self.submitted_queue[queue_idx] == idx) return true;
        }
        return false;
    }

    fn is_waiting_for_display_flip(self: *const Swapchain) bool {
        const flags = sdk.kernel.cpu_suspend_intr();
        defer sdk.kernel.cpu_resume_intr(flags);

        if (self.submitted_count > 0) return false;

        const start = (@as(usize, self.draw_idx) + 1) % BUFFER_COUNT;
        var offset: usize = 0;
        while (offset < BUFFER_COUNT) : (offset += 1) {
            const idx: BufferIndex = @intCast((start + offset) % BUFFER_COUNT);
            if (idx == self.front_idx) continue;
            if (self.pending_idx) |pending| {
                if (idx == pending) continue;
            }
            return false;
        }

        return true;
    }

    fn publish_finished_ge_buffer(self: *Swapchain) void {
        const flags = sdk.kernel.cpu_suspend_intr();
        if (self.submitted_count > 0) {
            const idx = self.submitted_queue[self.submitted_head];
            self.submitted_head = (self.submitted_head + 1) % BUFFER_COUNT;
            self.submitted_count -= 1;
            self.pending_idx = idx;
        }
        sdk.kernel.cpu_resume_intr_with_sync(flags);
    }

    fn apply_pending_display(self: *Swapchain) void {
        const flags = sdk.kernel.cpu_suspend_intr();
        if (self.pending_idx) |idx| {
            display.set_frame_buf(
                self.buffers_abs[@intCast(idx)],
                SCR_BUF_WIDTH,
                display_pixel_format,
                .immediate,
            ) catch {};
            self.front_idx = idx;
            self.pending_idx = null;
        }
        sdk.kernel.cpu_resume_intr_with_sync(flags);
    }
};

var swapchain: Swapchain = .{};

fn vblank_handler(_: c_int, arg: ?*anyopaque) callconv(.c) void {
    const sc: *Swapchain = @ptrCast(@alignCast(arg orelse return));
    sc.apply_pending_display();
}

fn ge_finish_callback(_: c_int, arg: ?*anyopaque) callconv(.c) void {
    const sc: *Swapchain = @ptrCast(@alignCast(arg orelse return));
    sc.publish_finished_ge_buffer();
}

// ---- ge_list display list ownership ----------------------------------------

/// Active command buffer for the current frame, re-initialized at the
/// start of every frame inside `begin_list`.
var cmd: ge_list.CommandBuffer = undefined;

/// GE callback id. The finish callback releases the shared display list and
/// depth buffer for the next frame, so registration is required.
var ge_callback_id: i32 = 0;

fn nop_ge_callback(_: c_int, _: ?*anyopaque) callconv(.c) void {}

/// Move the GE's stall address to the current write cursor so the
/// hardware can drain commands written so far. Direct-mode equivalent of
/// gu's internal `update_stall_addr()`.
var current_qid: i32 = 0;

fn advance_stall() void {
    ge_list.list_update_stall_addr(current_qid, cmd.current()) catch {};
}

/// Reset the command buffer to the start of the shared GE list and
/// re-enqueue it with stall=start, mirroring `sceGuStart(.Direct, ...)`.
/// The GE will not execute anything until `advance_stall` is called.
fn begin_list() void {
    const list = swapchain.list_uncached;
    cmd = ge_list.CommandBuffer.init(list);
    current_qid = ge_list.list_enqueue(
        list.ptr,
        list.ptr,
        ge_callback_id,
        null,
    ) catch |err| std.debug.panic("psp_gfx_ge: list_enqueue failed: {s}", .{@errorName(err)});
}

/// Emit `finish` + `end` and advance the stall past them. Equivalent to
/// `sceGuFinish()`. After this call the GE will drain everything queued.
fn finish_list() void {
    must(cmd.finish(0));
    must(cmd.end());
    advance_stall();
}

fn finish_frame_list() void {
    must(cmd.finish(0));
    must(cmd.end());
    swapchain.mark_submitted();
    advance_stall();
}

/// Bail out on a write error. The display list buffer is large enough to
/// hold any reasonable frame, so overflows mean we have a bug.
fn must(result: ge_list.WriteError!void) void {
    result catch |err| std.debug.panic("psp_gfx_ge: GE list write failed: {s}", .{@errorName(err)});
}

// ---- GE register reset list -----------------------------------------------
//
// Verbatim copy of pspsdk's `ge_init_list` (the table sceGuInit enqueues to
// reset every GE register to a known default before any user state is set
// up). The trailing 0x0f / 0x0c / 0 / 0 entries — finish, end, padding —
// are dropped because we splice this into the middle of our own display
// list rather than running it as a separate enqueue.

const ge_init_state_words = [_]u32{
    0x01000000, 0x02000000, 0x10000000, 0x12000000, 0x13000000, 0x15000000, 0x16000000, 0x17000000,
    0x18000000, 0x19000000, 0x1a000000, 0x1b000000, 0x1c000000, 0x1d000000, 0x1e000000, 0x1f000000,
    0x20000000, 0x21000000, 0x22000000, 0x23000000, 0x24000000, 0x25000000, 0x26000000, 0x27000000,
    0x28000000, 0x2a000000, 0x2b000000, 0x2c000000, 0x2d000000, 0x2e000000, 0x2f000000, 0x30000000,
    0x31000000, 0x32000000, 0x33000000, 0x36000000, 0x37000000, 0x38000000, 0x3a000000, 0x3b000000,
    0x3c000000, 0x3d000000, 0x3e000000, 0x3f000000, 0x40000000, 0x41000000, 0x42000000, 0x43000000,
    0x44000000, 0x45000000, 0x46000000, 0x47000000, 0x48000000, 0x49000000, 0x4a000000, 0x4b000000,
    0x4c000000, 0x4d000000, 0x50000000, 0x51000000, 0x53000000, 0x54000000, 0x55000000, 0x56000000,
    0x57000000, 0x58000000, 0x5b000000, 0x5c000000, 0x5d000000, 0x5e000000, 0x5f000000, 0x60000000,
    0x61000000, 0x62000000, 0x63000000, 0x64000000, 0x65000000, 0x66000000, 0x67000000, 0x68000000,
    0x69000000, 0x6a000000, 0x6b000000, 0x6c000000, 0x6d000000, 0x6e000000, 0x6f000000, 0x70000000,
    0x71000000, 0x72000000, 0x73000000, 0x74000000, 0x75000000, 0x76000000, 0x77000000, 0x78000000,
    0x79000000, 0x7a000000, 0x7b000000, 0x7c000000, 0x7d000000, 0x7e000000, 0x7f000000, 0x80000000,
    0x81000000, 0x82000000, 0x83000000, 0x84000000, 0x85000000, 0x86000000, 0x87000000, 0x88000000,
    0x89000000, 0x8a000000, 0x8b000000, 0x8c000000, 0x8d000000, 0x8e000000, 0x8f000000, 0x90000000,
    0x91000000, 0x92000000, 0x93000000, 0x94000000, 0x95000000, 0x96000000, 0x97000000, 0x98000000,
    0x99000000, 0x9a000000, 0x9b000000, 0x9c000000, 0x9d000000, 0x9e000000, 0x9f000000, 0xa0000000,
    0xa1000000, 0xa2000000, 0xa3000000, 0xa4000000, 0xa5000000, 0xa6000000, 0xa7000000, 0xa8040004,
    0xa9000000, 0xaa000000, 0xab000000, 0xac000000, 0xad000000, 0xae000000, 0xaf000000, 0xb0000000,
    0xb1000000, 0xb2000000, 0xb3000000, 0xb4000000, 0xb5000000, 0xb8000101, 0xb9000000, 0xba000000,
    0xbb000000, 0xbc000000, 0xbd000000, 0xbe000000, 0xbf000000, 0xc0000000, 0xc1000000, 0xc2000000,
    0xc3000000, 0xc4000000, 0xc5000000, 0xc6000000, 0xc7000000, 0xc8000000, 0xc9000000, 0xca000000,
    0xcb000000, 0xcc000000, 0xcd000000, 0xce000000, 0xcf000000, 0xd0000000, 0xd2000000, 0xd3000000,
    0xd4000000, 0xd5000000, 0xd6000000, 0xd7000000, 0xd8000000, 0xd9000000, 0xda000000, 0xdb000000,
    0xdc000000, 0xdd000000, 0xde000000, 0xdf000000, 0xe0000000, 0xe1000000, 0xe2000000, 0xe3000000,
    0xe4000000, 0xe5000000, 0xe6000000, 0xe7000000, 0xe8000000, 0xe9000000, 0xeb000000, 0xec000000,
    0xee000000, 0xf0000000, 0xf1000000, 0xf2000000, 0xf3000000, 0xf4000000, 0xf5000000, 0xf6000000,
    0xf7000000, 0xf8000000, 0xf9000000,
};

fn emit_ge_init_state() void {
    for (ge_init_state_words) |word| {
        must(cmd.emit_word(word));
    }
}

// ---- clear sprite buffer ---------------------------------------------------
//
// gu's `sceGuClear` synthesizes a strip of full-screen sprites in scratch
// display-list memory each call. We instead pre-allocate the same vertex
// layout once and rebuild only when the clear color changes; the layout
// itself is fixed for our 480x272 framebuffer.

const ClearVertex = extern struct {
    color: u32,
    x: u16,
    y: u16,
    z: u16,
    pad: u16 = 0,
};

const CLEAR_COUNT: usize = ((SCREEN_WIDTH + 63) / 64) * 2;
var clear_vertices: [Swapchain.BUFFER_COUNT][CLEAR_COUNT]ClearVertex align(16) = undefined;
var clear_filter_for_buffer: [Swapchain.BUFFER_COUNT]u32 =
    [_]u32{0xFFFFFFFF} ** Swapchain.BUFFER_COUNT; // sentinel forces an initial rebuild

const clear_vertex_type = VertexType{
    .color = .Color8888,
    .vertex = .Vertex16Bit,
    .transform = .Transform2D,
};

fn build_clear_vertices(buffer_idx: Swapchain.BufferIndex, filter: u32) void {
    const buffer = @as(usize, buffer_idx);
    var i: usize = 0;
    while (i < CLEAR_COUNT) : (i += 1) {
        const idx: u16 = @intCast(i);
        const j: u16 = idx >> 1;
        const k: u16 = idx & 1;
        clear_vertices[buffer][i] = .{
            .color = filter,
            .x = (j + k) * 64,
            .y = k * @as(u16, @intCast(SCREEN_HEIGHT)),
            .z = 1, // matches gu.clear_depth(1) in the existing backend
        };
    }
    sdk.kernel.dcache_writeback_range(@ptrCast(&clear_vertices[buffer]), @sizeOf(@TypeOf(clear_vertices[buffer])));
}

/// Pack the clear color the way `sceGuClear` does for the active pixel
/// format. Stencil is always zero since the engine never sets it.
fn pack_clear_filter(color: u24) u32 {
    return @as(u32, color);
}

fn ensure_clear_vertices(buffer_idx: Swapchain.BufferIndex, filter: u32) void {
    const buffer = @as(usize, buffer_idx);
    if (filter != clear_filter_for_buffer[buffer]) {
        build_clear_vertices(buffer_idx, filter);
        clear_filter_for_buffer[buffer] = filter;
    }
}

fn emit_clear(self: *Self, targets: ge_list.ClearFlags) void {
    const buffer_idx = swapchain.draw_idx;
    const filter = pack_clear_filter(self.clear_color);
    ensure_clear_vertices(buffer_idx, filter);

    must(cmd.emit_clear(true, targets));
    must(cmd.vertex_type(@bitCast(clear_vertex_type)));
    must(cmd.vertex_address(@intFromPtr(&clear_vertices[@intCast(buffer_idx)])));
    must(cmd.primitive(.sprites, @intCast(CLEAR_COUNT)));
    must(cmd.emit_clear(false, .{}));
    advance_stall();
}

// ---- depth range helper ----------------------------------------------------
//
// Mirrors the math gu does inside `sceGuDepthRange` so reverse-Z (near=65535,
// far=0) reaches the same depth_scale_position / depth_bounds values that
// the existing gu backend ends up emitting.

fn emit_depth_range(near_value: u16, far_value: u16) void {
    const max: i32 = @as(i32, near_value) + @as(i32, far_value);
    const z: f32 = @floatFromInt(@divTrunc(max, 2));
    must(cmd.depth_scale_position(
        z - @as(f32, @floatFromInt(@as(i32, near_value))),
        z,
    ));
    must(cmd.depth_bounds(near_value, far_value));
}

// ---- engine state ----------------------------------------------------------

clear_color: u24 = 0x000000,

fn init(ctx: *anyopaque) !void {
    const self = Util.ctx_to_self(Self, ctx);
    self.clear_color = 0x000000;

    swapchain.init();

    // The GE callback owns the GE finish subinterrupt internally. We use its
    // finish callback instead of registering PSP_GE_INT / subintr 1 directly.
    const cb_data = ge.CallbackData{
        .signal_func = nop_ge_callback,
        .signal_arg = null,
        .finish_func = ge_finish_callback,
        .finish_arg = &swapchain,
    };
    ge_callback_id = try ge.set_callback(cb_data);

    begin_list();

    // Reset every GE register the same way pspsdk's sceGuInit does, so we
    // start from a known state regardless of whatever the previous program
    // (XMB / loader / homebrew) left behind.
    emit_ge_init_state();

    must(cmd.pixel_format(ge_pixel_format));
    must(cmd.frame_buffer(swapchain.buffers_rel[swapchain.draw_idx], SCR_BUF_WIDTH));
    must(cmd.depth_buffer(swapchain.depth_buffer_rel, SCR_BUF_WIDTH));

    // Equivalent to gu.disp_buffer's side effect of enabling LCD mode the
    // first time it is called.
    try display.set_mode(.lcd, SCREEN_WIDTH, SCREEN_HEIGHT);

    // Drawing region (rasterizer bounds). gu emits this from inside
    // sceGuDispBuffer; we have to do it explicitly.
    must(cmd.region(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT));

    must(cmd.screen_offset(2048 - (SCREEN_WIDTH / 2), 2048 - (SCREEN_HEIGHT / 2)));
    must(cmd.viewport(2048, 2048, SCREEN_WIDTH, SCREEN_HEIGHT));

    // Reverse-Z, matching gu.depth_range(65535, 0) in psp_gfx.zig.
    emit_depth_range(65535, 0);

    must(cmd.scissor(0, 0, SCREEN_WIDTH - 1, SCREEN_HEIGHT - 1));
    must(cmd.depth_func(.greater_or_equal));
    must(cmd.enable(.depth_test, true));
    must(cmd.shade_model(.smooth));
    must(cmd.front_face_clockwise(false));
    must(cmd.enable(.cull_face, true));
    must(cmd.enable(.clip_planes, false));
    clip_planes_enabled = false;
    must(cmd.enable(.alpha_test, true));
    must(cmd.alpha_test(.greater, 16, 0xFF));
    must(cmd.enable(.alpha_blend, true));
    must(cmd.blend_func(.add, .source_alpha, .one_minus_source_alpha, 0, 0));
    alpha_blend_enabled = true;
    must(cmd.enable(.texture_mapping, true));
    must(cmd.texture_scale(1.0, 1.0));
    must(cmd.texture_offset(0.0, 0.0));

    // Initialize all matrix slots to identity so hardware registers are
    // never garbage. The new ge command_buffer takes raw [16]f32 — the
    // view/world/texture variants only emit the 12 elements actually
    // consumed by the 3x4 GE matrix uploads.
    const identity = [_]f32{
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1,
    };
    must(cmd.projection_matrix(&identity));
    must(cmd.view_matrix(&identity));
    must(cmd.world_matrix(&identity));
    must(cmd.texture_matrix(&identity));

    finish_list();
    _ = ge_list.draw_sync(.wait);

    try swapchain.install_vblank_handler();
    try swapchain.prime_display();
    try display.wait_vblank_start();
}

fn deinit(_: *anyopaque) void {
    swapchain.deinit();
    if (ge_callback_id > 0) {
        ge.unset_callback(ge_callback_id) catch {};
        ge_callback_id = 0;
    }
}

fn set_alpha_blend(_: *anyopaque, enabled: bool) void {
    if (enabled == alpha_blend_enabled) return;
    alpha_blend_enabled = enabled;
    must(cmd.enable(.alpha_blend, enabled));
    must(cmd.enable(.alpha_test, enabled));
    advance_stall();
}

fn set_clip_planes(_: *anyopaque, enabled: bool) void {
    if (enabled == clip_planes_enabled) return;
    clip_planes_enabled = enabled;
    must(cmd.enable(.clip_planes, enabled));
    advance_stall();
}

fn set_fog(_: *anyopaque, enabled: bool, start: f32, end: f32, r: f32, g: f32, b: f32) void {
    if (enabled) {
        const ri: u32 = @intFromFloat(@max(0.0, @min(1.0, r)) * 255.0);
        const gi: u32 = @intFromFloat(@max(0.0, @min(1.0, g)) * 255.0);
        const bi: u32 = @intFromFloat(@max(0.0, @min(1.0, b)) * 255.0);
        const color: u24 = @intCast((bi << 16) | (gi << 8) | ri);
        must(cmd.fog(start, end, color));
        if (!fog_enabled) {
            must(cmd.enable(.fog, true));
            fog_enabled = true;
        }
    } else if (fog_enabled) {
        must(cmd.enable(.fog, false));
        fog_enabled = false;
    }
    advance_stall();
}

fn set_clear_color(ctx: *anyopaque, r: f32, g: f32, b: f32, _: f32) void {
    const self = Util.ctx_to_self(Self, ctx);
    const ri: u8 = @intFromFloat(@max(0.0, @min(1.0, r)) * 255.0);
    const gi: u8 = @intFromFloat(@max(0.0, @min(1.0, g)) * 255.0);
    const bi: u8 = @intFromFloat(@max(0.0, @min(1.0, b)) * 255.0);
    self.clear_color = (@as(u24, bi) << 16) | (@as(u24, gi) << 8) | ri;
}

fn mat4_as_floats(mat: *const Mat4) *const [16]f32 {
    return @ptrCast(&mat.data);
}

fn set_proj_matrix(_: *anyopaque, mat: *const Mat4) void {
    must(cmd.projection_matrix(mat4_as_floats(mat)));
    advance_stall();
}

fn set_view_matrix(_: *anyopaque, mat: *const Mat4) void {
    must(cmd.view_matrix(mat4_as_floats(mat)));
    advance_stall();
}

fn start_frame(ctx: *anyopaque) bool {
    const self = Util.ctx_to_self(Self, ctx);

    while (!swapchain.acquire_draw_buffer()) {
        if (swapchain.is_waiting_for_display_flip()) return false;
    }

    begin_list();

    must(cmd.pixel_format(ge_pixel_format));
    must(cmd.frame_buffer(swapchain.buffers_rel[swapchain.draw_idx], SCR_BUF_WIDTH));
    must(cmd.depth_buffer(swapchain.depth_buffer_rel, SCR_BUF_WIDTH));
    emit_clear(self, .{ .color = true, .stencil = true, .depth = true });

    return true;
}

fn clear_depth(ctx: *anyopaque) void {
    const self = Util.ctx_to_self(Self, ctx);
    emit_clear(self, .{ .depth = true });
}

fn end_frame(_: *anyopaque) void {
    finish_frame_list();
}

// ---- pipelines -------------------------------------------------------------

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

// ---- meshes ---------------------------------------------------------------

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

    must(cmd.world_matrix(mat4_as_floats(model)));

    if (pl.uv_unorm8) {
        must(cmd.texture_offset(1.0, 1.0));
        must(cmd.texture_scale(0.5, 0.5));
    } else {
        must(cmd.texture_offset(0.0, 0.0));
        must(cmd.texture_scale(1.0, 1.0));
    }

    must(cmd.vertex_type(@as(u24, @bitCast(pl.vertex_type))));
    must(cmd.vertex_address(@intFromPtr(data)));
    must(cmd.primitive(switch (primitive) {
        .triangles => .triangles,
        .lines => .lines,
    }, @intCast(count)));
    advance_stall();
}

// ---- textures -------------------------------------------------------------

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

    const layout: ge_list.TextureDataLayout = if (tex.swizzled) .swizzled else .linear;

    must(cmd.texture_mode(tex_pixel_format, 0, .single, layout));
    must(cmd.texture_flush());
    must(cmd.texture_image(.level0, @intCast(tex.width), @intCast(tex.height), @intCast(tex.width), tex.data));
    must(cmd.texture_flush());
    must(cmd.texture_function(.{ .effect = .modulate, .component = .rgba }));
    must(cmd.texture_filter(.nearest, .nearest));
    must(cmd.texture_scale(1.0, 1.0));
    must(cmd.texture_offset(0.0, 0.0));
    advance_stall();
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
        switch (options.config.psp_display_mode) {
            .rgba8888 => .Psm8888,
            .rgb565 => .Psm4444,
        },
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
