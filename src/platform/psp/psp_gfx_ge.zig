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
const vram = @import("vram.zig");
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
    buffers_abs: [BUFFER_COUNT]?[]align(16) u8 = [_]?[]align(16) u8{null} ** BUFFER_COUNT,
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
        self.buffers_abs = [_]?[]align(16) u8{null} ** BUFFER_COUNT;

        for (0..BUFFER_COUNT) |i| {
            const buffer = vram.alloc_relative_buffer(SCR_BUF_WIDTH, SCREEN_HEIGHT, vram_color_format);
            self.buffers_rel[i] = buffer.ptr;
            const relative_addr: usize = if (buffer.ptr) |ptr| @intFromPtr(ptr) else 0;
            const ptr: [*]align(16) u8 = @ptrFromInt((relative_addr + vram_base) | uncached);
            self.buffers_abs[i] = ptr[0..buffer.len];
            self.clear_buffer(@intCast(i));
        }

        self.depth_buffer_rel = vram.alloc_relative(SCR_BUF_WIDTH, SCREEN_HEIGHT, .Psm4444);
    }

    fn clear_buffer(self: *Swapchain, idx: BufferIndex) void {
        const buffer = self.buffers_abs[@intCast(idx)].?;
        @memset(buffer[0 .. SCR_BUF_WIDTH * SCREEN_HEIGHT * frame_bpp], 0);
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
            @ptrCast(self.buffers_abs[@intCast(self.front_idx)].?.ptr),
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
                @ptrCast(self.buffers_abs[@intCast(pending)].?.ptr),
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
                @ptrCast(self.buffers_abs[@intCast(idx)].?.ptr),
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

// ---- dialog suspend / resume ----------------------------------------------
//
// PSP system utility dialogs (OSK, netconf) need exclusive GE ownership.
// These functions bracket the dialog's sceGu-based render loop, stopping
// our interrupt handlers and display-list management so the firmware
// dialog renderer can take over safely.

pub const DialogBufferInfo = struct {
    front_buffer_rel: ?*anyopaque,
    back_buffer_rel: ?*anyopaque,
    front_buffer_abs: ?*anyopaque,
    back_buffer_abs: ?*anyopaque,
    depth_buffer_rel: ?*anyopaque,
};

pub fn get_dialog_buffer_info() DialogBufferInfo {
    const front: usize = @intCast(swapchain.front_idx);
    const back: usize = (front +% 1) % Swapchain.BUFFER_COUNT;
    return .{
        .front_buffer_rel = swapchain.buffers_rel[front],
        .back_buffer_rel = swapchain.buffers_rel[back],
        .front_buffer_abs = if (swapchain.buffers_abs[front]) |b| @ptrCast(b.ptr) else null,
        .back_buffer_abs = if (swapchain.buffers_abs[back]) |b| @ptrCast(b.ptr) else null,
        .depth_buffer_rel = swapchain.depth_buffer_rel,
    };
}

/// Wait for any in-flight GE work to complete.
pub fn dialog_drain() void {
    _ = ge_list.draw_sync(.wait);
}

/// Begin a GE display list for dialog rendering. Uses the same list
/// buffer and callback as normal frames. Drains any prior list first
/// so the enqueue doesn't conflict. Resets region/scissor to full screen
/// so the clear covers everything.
pub fn dialog_begin() void {
    _ = ge_list.draw_sync(.wait);
    begin_list();
    must(cmd.frame_buffer(swapchain.buffers_rel[swapchain.draw_idx], SCR_BUF_WIDTH));
    must(cmd.pixel_format(ge_pixel_format));
    must(cmd.region(0, 0, SCREEN_WIDTH, SCREEN_HEIGHT));
    must(cmd.scissor(0, 0, SCREEN_WIDTH - 1, SCREEN_HEIGHT - 1));
}

/// Emit a color-buffer clear into the active dialog list.
pub fn dialog_clear() void {
    const buffer_idx = swapchain.draw_idx;
    const filter: u32 = 0x000000; // black
    ensure_clear_vertices(buffer_idx, filter);

    must(cmd.emit_clear(true, .{ .color = true, .depth = true }));
    must(cmd.vertex_type(@bitCast(clear_vertex_type)));
    must(cmd.vertex_address(@intFromPtr(&clear_vertices[@intCast(buffer_idx)])));
    must(cmd.primitive(.sprites, @intCast(CLEAR_COUNT)));
    must(cmd.emit_clear(false, .{}));
    advance_stall();
}

/// Finish the dialog list and wait for the GE to drain it.
pub fn dialog_finish() void {
    finish_list();
    _ = ge_list.draw_sync(.wait);
}

/// Swap the dialog display buffer. Alternates draw_idx / front_idx and
/// points the display controller at the new front.
pub fn dialog_swap() void {
    const old_front = swapchain.front_idx;
    swapchain.front_idx = swapchain.draw_idx;
    swapchain.draw_idx = old_front;
    // display.set_frame_buf(
    //     @ptrCast(swapchain.buffers_abs[@intCast(swapchain.front_idx)].?.ptr),
    //     SCR_BUF_WIDTH,
    //     display_pixel_format,
    //     .next_vblank,
    // ) catch {};
}

pub fn suspend_for_dialog() void {
    // Drain any in-flight GE work.
    finish_list();
    _ = ge_list.draw_sync(.wait);

    // Stop our interrupt handlers so they don't fire during the dialog.
    swapchain.deinit();

    // Unregister our GE finish callback; sceGuInit will register its own.
    if (ge_callback_id > 0) {
        ge.unset_callback(ge_callback_id) catch {};
        ge_callback_id = 0;
    }
}

pub fn resume_from_dialog() void {
    // Re-register our GE finish callback.
    const cb_data = ge.CallbackData{
        .signal_func = nop_ge_callback,
        .signal_arg = null,
        .finish_func = ge_finish_callback,
        .finish_arg = &swapchain,
    };
    ge_callback_id = ge.set_callback(cb_data) catch 0;

    // Reset swapchain queue state to a clean slate.
    swapchain.pending_idx = null;
    swapchain.submitted_head = 0;
    swapchain.submitted_count = 0;

    // Re-install VBlank handler and prime the display.
    swapchain.install_vblank_handler() catch {};
    swapchain.prime_display() catch {};
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

/// Number of mip levels generated below the base level when a texture is
/// forced VRAM-resident. The base counts as level 0; mip 1 is half-size,
/// mip 2 is quarter-size, and mip 3 is eighth-size.
const MAX_MIP_LEVELS: u8 = 3;

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
        const dst = tex.vram_data orelse @panic("psp_gfx_ge: VRAM texture missing backing slice");
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

    const layout: ge_list.TextureDataLayout = if (tex.swizzled) .swizzled else .linear;

    must(cmd.texture_mode(tex_pixel_format, @intCast(tex.mip_count), .single, layout));
    must(cmd.texture_flush());
    must(cmd.texture_image(.level0, @intCast(tex.width), @intCast(tex.height), @intCast(tex.width), tex.data));
    var i: u8 = 0;
    while (i < tex.mip_count) : (i += 1) {
        const mip = tex.mips[i];
        const level: ge_list.TextureLevel = @enumFromInt(@as(u3, @intCast(i + 1)));
        must(cmd.texture_image(level, @intCast(mip.width), @intCast(mip.height), @intCast(mip.width), mip.data));
    }
    must(cmd.texture_flush());
    must(cmd.texture_function(.{ .effect = .modulate, .component = .rgba }));
    if (tex.mip_count > 0) {
        must(cmd.texture_filter(.nearest_mipmap_nearest, .nearest));
    } else {
        must(cmd.texture_filter(.nearest, .nearest));
    }
    must(cmd.texture_scale(1.0, 1.0));
    must(cmd.texture_offset(0.0, 0.0));
    advance_stall();
}

fn destroy_texture(_: *anyopaque, handle: Texture.Handle) void {
    // VRAM allocations are static and cannot be freed individually.
    _ = textures.remove_element(handle);
}

fn vram_pixel_format() gu_types.GuPixelFormat {
    return switch (options.config.psp_display_mode) {
        .rgba8888 => .Psm8888,
        .rgb565 => .Psm4444,
    };
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
    if (!options.config.psp_mipmaps) return;
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

        const vram_buf = vram.alloc_absolute_slice(dst_w, dst_h, vram_pixel_format());

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
    const vram_data = vram.alloc_absolute_slice(tex.width, tex.height, vram_pixel_format());

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
