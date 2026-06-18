const std = @import("std");
const zitrus = @import("zitrus");
const app_3ds = @import("app.zig");
const Self = @This();

const horizon = zitrus.horizon;
const pica = zitrus.hardware.pica;
const GraphicsServerGpu = horizon.services.GraphicsServerGpu;
const Graphics = GraphicsServerGpu.Graphics;
const Framebuffer = Graphics.Framebuffer;

const VIRTUAL_WIDTH = 400;
const VIRTUAL_HEIGHT = 240;

alloc: std.mem.Allocator,
gfx: ?Graphics = null,
top: ?Framebuffer = null,
bottom: ?Framebuffer = null,
sync: bool = true,
applet_released: bool = false,
present_bottom: bool = false,

pub fn init(self: *Self, _: u32, _: u32, _: [:0]const u8, _: bool, sync: bool, _: bool) anyerror!void {
    const app = app_3ds.currentApplication() orelse return error.NoCurrentApplication;

    self.sync = sync;

    var graphics = try Graphics.init(app.gsp);
    errdefer graphics.deinit(app.gsp);

    var top = try Framebuffer.init(.{
        .screen = .top,
        .double_buffer = true,
        .mode = .full,
        .pixel_format = .bgr888,
    }, horizon.heap.linear_page_allocator);
    errdefer top.deinit(horizon.heap.linear_page_allocator);

    var bottom = try Framebuffer.init(.{
        .screen = .bottom,
        .double_buffer = true,
        .mode = .@"2d",
        .pixel_format = .bgr888,
    }, horizon.heap.linear_page_allocator);
    errdefer bottom.deinit(horizon.heap.linear_page_allocator);

    clear_all_buffers(&top);
    clear_all_buffers(&bottom);
    top.flush();
    bottom.flush();

    top.swap(&graphics, .ignore_stereo);
    bottom.swap(&graphics, .ignore_stereo);
    top.swap(&graphics, .ignore_stereo);
    bottom.swap(&graphics, .ignore_stereo);
    if (self.sync) wait_vblank(&graphics, true) catch {};
    app.gsp.sendSetLcdForceBlack(false) catch {};

    self.gfx = graphics;
    self.top = top;
    self.bottom = bottom;
}

pub fn deinit(self: *Self) void {
    const app = app_3ds.currentApplication();
    const must_close = if (app) |a| a.app.flags.must_close else true;

    if (app) |a| {
        if (self.applet_released and !must_close) self.resume_from_applet();
        if (!must_close) {
            if (self.gfx) |*graphics| wait_vblank(graphics, true) catch {};
            a.gsp.sendSetLcdForceBlack(true) catch {};
        }
    }
    self.applet_released = false;

    if (self.bottom) |*bottom| {
        bottom.deinit(horizon.heap.linear_page_allocator);
        self.bottom = null;
    }
    if (self.top) |*top| {
        top.deinit(horizon.heap.linear_page_allocator);
        self.top = null;
    }
    if (self.gfx) |*graphics| {
        if (app) |a| graphics.deinit(a.gsp);
        self.gfx = null;
    }
}

pub fn suspend_for_applet(self: *Self) !GraphicsServerGpu.ScreenCapture {
    const app = app_3ds.currentApplication() orelse return error.NoCurrentApplication;
    const graphics = if (self.gfx) |*g| g else return error.GraphicsNotInitialized;
    if (self.applet_released) return self.current_capture();

    self.present_bottom = false;
    wait_vblank(graphics, true) catch {};
    const capture = try self.current_capture();
    clear_framebuffer_updates(graphics);
    graphics.discardInterrupts();
    try app.gsp.sendSaveVRAMSysArea();
    try app.gsp.sendReleaseRight();
    graphics.gsp_owned = false;
    self.applet_released = true;
    return capture;
}

pub fn resume_from_applet(self: *Self) void {
    if (!self.applet_released) return;

    const app = app_3ds.currentApplication() orelse return;
    const graphics = if (self.gfx) |*g| g else return;
    graphics.reacquire(app.gsp) catch |err| {
        std.log.err("3DS graphics reacquire failed: {s}", .{@errorName(err)});
        return;
    };
    // Keep deinit's ownership check accurate after returning from the applet.
    graphics.gsp_owned = true;
    self.applet_released = false;
    app.gsp.sendSetLcdForceBlack(false) catch {};
}

pub fn update(_: *Self) bool {
    return true;
}

pub fn draw(self: *Self) void {
    const top = if (self.top) |*t| t else return;
    const graphics = if (self.gfx) |*g| g else return;
    const present_bottom = self.present_bottom;
    defer self.present_bottom = false;

    top.flush();
    top.swap(graphics, .ignore_stereo);
    if (present_bottom) {
        if (self.bottom) |*bottom| {
            bottom.flush();
            bottom.swap(graphics, .ignore_stereo);
        }
    }
    if (self.sync) {
        if (present_bottom) {
            wait_vblank(graphics, true) catch {};
        } else {
            wait_vblank(graphics, false) catch {};
        }
    }
}

pub fn get_width(_: *Self) u32 {
    return VIRTUAL_WIDTH;
}

pub fn get_height(_: *Self) u32 {
    return VIRTUAL_HEIGHT;
}

fn clear_all_buffers(fb: *Framebuffer) void {
    @memset(fb.allocation, 0);
}

fn clear_framebuffer_updates(graphics: *Graphics) void {
    const clean = std.mem.zeroes(GraphicsServerGpu.FramebufferInfo.Header);
    @atomicStore(GraphicsServerGpu.FramebufferInfo.Header, &graphics.shared_memory.framebuffers[graphics.thread_index][0].header, clean, .release);
    @atomicStore(GraphicsServerGpu.FramebufferInfo.Header, &graphics.shared_memory.framebuffers[graphics.thread_index][1].header, clean, .release);
}

fn current_capture(self: *Self) !GraphicsServerGpu.ScreenCapture {
    const top = if (self.top) |*t| t else return error.GraphicsNotInitialized;
    const bottom = if (self.bottom) |*b| b else return error.GraphicsNotInitialized;

    return .{
        .top = capture_info(top, .ignore_stereo),
        .bottom = capture_info(bottom, .ignore_stereo),
    };
}

fn capture_info(fb: *Framebuffer, ignore_stereo: Framebuffer.IgnoreStereo) GraphicsServerGpu.ScreenCapture.Info {
    const displayed = displayed_framebuffer(fb);
    const left = framebuffer_side(fb, displayed, .left).ptr;
    const right = if (fb.config.mode == .@"3d" and ignore_stereo == .none)
        framebuffer_side(fb, displayed, .right).ptr
    else
        left;

    return .{
        .left_vaddr = @ptrCast(left),
        .right_vaddr = @ptrCast(right),
        .format = framebuffer_format(fb, ignore_stereo),
        .stride = (fb.config.pixel_format.bytesPerPixel() * fb.config.screen.width()) << @intFromBool(fb.config.mode == .full),
    };
}

fn displayed_framebuffer(fb: *const Framebuffer) u1 {
    return fb.current_framebuffer ^ @as(u1, @intFromBool(fb.config.double_buffer));
}

fn framebuffer_side(fb: *Framebuffer, index: u1, side: Framebuffer.Side) []u8 {
    std.debug.assert((fb.config.mode != .@"3d" and side != .right) or fb.config.mode == .@"3d");
    const side_offset = @as(usize, @intFromEnum(side)) * (fb.framebuffer_bytes >> 1);
    const start = (fb.framebuffer_bytes * @as(usize, index)) + side_offset;
    const len = fb.framebuffer_bytes >> @intFromBool(fb.config.mode == .@"3d");
    return fb.allocation[start..][0..len];
}

fn framebuffer_format(fb: *const Framebuffer, ignore_stereo: Framebuffer.IgnoreStereo) pica.DisplayController.Framebuffer.Format {
    return .{
        .pixel_format = fb.config.pixel_format,
        .dma_size = fb.config.dma_size,
        .interlacing = if (fb.config.mode == .@"3d" and ignore_stereo == .none) .enable else .none,
        .half_rate = fb.config.screen == .top and fb.config.mode == .@"2d",
    };
}

fn wait_vblank(graphics: ?*Graphics, comptime include_bottom: bool) !void {
    const gfx = graphics orelse return;
    gfx.discardInterrupts();
    var bottom = !include_bottom;
    while (true) {
        const interrupts = try gfx.waitInterrupts();
        if (interrupts.contains(.vblank_bottom)) bottom = true;
        if (bottom and interrupts.contains(.vblank_top)) return;
    }
}
