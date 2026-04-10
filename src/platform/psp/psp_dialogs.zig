// PSP system utility dialogs: On-Screen Keyboard and Network Configuration.
//
// These dialogs take exclusive ownership of the GE hardware. The functions
// in this module handle the full suspend / dialog-loop / resume cycle so
// callers only need a single blocking call.

const std = @import("std");
const sdk = @import("pspsdk");
const utility = sdk.utility;
const display = sdk.display;
const gu = sdk.gu;
const gfx = @import("psp_gfx_ge.zig");

const options = @import("options");

const SCREEN_WIDTH = sdk.extra.constants.SCREEN_WIDTH;
const SCREEN_HEIGHT = sdk.extra.constants.SCREEN_HEIGHT;
const SCR_BUF_WIDTH = sdk.extra.constants.SCR_BUF_WIDTH;

const display_pixel_format: display.PixelFormat = switch (options.config.psp_display_mode) {
    .rgba8888 => .rgba8888,
    .rgb565 => .rgb565,
};

/// Small display list for sceGu during the dialog render loop.
var dialog_list: [256]u32 align(16) = undefined;

// ---- sceGu setup / teardown for dialog rendering --------------------------

fn initGuForDialog() void {
    const bufs = gfx.get_dialog_buffer_info();

    gu.init();
    gu.draw_buffer(display_pixel_format, bufs.front_buffer_rel, SCR_BUF_WIDTH);
    gu.disp_buffer(SCREEN_WIDTH, SCREEN_HEIGHT, bufs.back_buffer_rel, SCR_BUF_WIDTH);
    gu.depth_buffer(bufs.depth_buffer_rel, SCR_BUF_WIDTH);
    gu.display(true);
}

fn teardownGuForDialog() void {
    gu.sync(.Finish, .wait);
    gu.term();
}

// ---- common dialog base struct helper -------------------------------------

fn makeDialogCommon(comptime size: usize) utility.DialogCommon {
    var base = std.mem.zeroes(utility.DialogCommon);
    base.size = @intCast(size);
    base.language = utility.get_system_param_int(.int_language) catch 1;
    base.buttonSwap = utility.get_system_param_int(.int_unknown) catch 1;
    base.graphicsThread = 0x11;
    base.accessThread = 0x13;
    base.fontThread = 0x12;
    base.soundThread = 0x10;
    return base;
}

// ---- Network --------------------------------------------------------------

pub fn initNetwork() !void {
    try utility.load_net_module(.common);
    try utility.load_net_module(.inet);
    try sdk.net.init(128 * 1024, 42, 0, 42, 0);
    try sdk.net.inet_init();
    try sdk.net.apctl_init(0x10000, 48);
}

pub fn showNetDialog() bool {
    var data = std.mem.zeroes(utility.NetconfData);
    data.base = makeDialogCommon(@sizeOf(utility.NetconfData));
    data.action = 0; // PSP_NETCONF_ACTION_CONNECTAP

    var adhoc = std.mem.zeroes(sdk.c.types.pspUtilityNetconfAdhoc);
    data.adhocparam = &adhoc;

    gfx.suspend_for_dialog();
    defer gfx.resume_from_dialog();

    initGuForDialog();
    defer teardownGuForDialog();

    utility.netconf_init_start(&data) catch return false;

    var done = true;
    while (done) {
        gu.start(.Direct, &dialog_list);
        gu.clear(.{ .color = true });
        gu.finish();
        gu.sync(.Finish, .wait);

        switch (utility.netconf_get_status()) {
            .none => {
                done = false;
            },
            .visible => {
                utility.netconf_update(1) catch {};
            },
            .quit => {
                utility.netconf_shutdown_start() catch {};
            },
            else => {},
        }

        display.wait_vblank_start() catch {};
        gu.swap_buffers();
    }

    return data.base.result == 0;
}

// ---- On-Screen Keyboard ---------------------------------------------------

pub fn showOSK(description: []const u16, out_text: []u16, max_text_limit: c_int) c_int {
    var empty_text = [_]u16{0};
    var osk_data = std.mem.zeroes(sdk.c.types.SceUtilityOskData);
    osk_data.language = 0; // PSP_UTILITY_OSK_LANGUAGE_DEFAULT
    osk_data.lines = 1;
    osk_data.unk_24 = 1;
    osk_data.inputtype = 0; // PSP_UTILITY_OSK_INPUTTYPE_ALL
    osk_data.desc = @ptrCast(@constCast(description.ptr));
    osk_data.intext = @ptrCast(&empty_text);
    osk_data.outtextlength = @intCast(out_text.len);
    osk_data.outtextlimit = max_text_limit;
    osk_data.outtext = @ptrCast(out_text.ptr);

    var osk_params = std.mem.zeroes(utility.OskParams);
    osk_params.base = makeDialogCommon(@sizeOf(utility.OskParams));
    osk_params.datacount = 1;
    osk_params.data = &osk_data;

    gfx.suspend_for_dialog();
    defer gfx.resume_from_dialog();

    initGuForDialog();
    defer teardownGuForDialog();

    utility.osk_init_start(&osk_params) catch return -1;

    var done = true;
    while (done) {
        gu.start(.Direct, &dialog_list);
        gu.clear(.{ .color = true });
        gu.finish();
        gu.sync(.Finish, .wait);

        switch (utility.osk_get_status()) {
            .none => {
                done = false;
            },
            .visible => {
                utility.osk_update(1) catch {};
            },
            .quit => {
                utility.osk_shutdown_start() catch {};
            },
            else => {},
        }

        display.wait_vblank_start() catch {};
        gu.swap_buffers();
    }

    // PSP_UTILITY_OSK_RESULT_CANCELLED = 1
    if (osk_data.result == 1) return -1;

    return 0;
}
