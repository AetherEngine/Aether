// PSP system utility dialogs: On-Screen Keyboard and Network Configuration.
//
// Dialog rendering goes through the Aether GE backend's dialog_begin /
// dialog_clear / dialog_finish / dialog_swap helpers so we stay on the
// same command buffer and swapchain as the rest of the engine.

const std = @import("std");
const sdk = @import("pspsdk");
const utility = sdk.utility;
const display = sdk.display;
const gfx = @import("psp_gfx_ge.zig");

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

pub fn showNetDialog() bool {
    var data = std.mem.zeroes(utility.NetconfData);
    data.base = makeDialogCommon(@sizeOf(utility.NetconfData));
    data.action = 0; // PSP_NETCONF_ACTION_CONNECTAP

    var adhoc = std.mem.zeroes(sdk.c.types.pspUtilityNetconfAdhoc);
    data.adhocparam = &adhoc;

    sdk.extra.net.init() catch return false;
    utility.netconf_init_start(&data) catch return false;

    var done = true;
    while (done) {
        gfx.dialog_begin();
        gfx.dialog_clear();
        gfx.dialog_finish();

        switch (utility.netconf_get_status()) {
            .none => done = false,
            .visible => utility.netconf_update(1) catch {},
            .quit => utility.netconf_shutdown_start() catch {},
            else => {},
        }

        display.wait_vblank_start() catch {};
        gfx.dialog_swap();
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

    utility.osk_init_start(&osk_params) catch return -1;

    var done = true;
    while (done) {
        gfx.dialog_begin();
        gfx.dialog_finish();

        switch (utility.osk_get_status()) {
            .none => done = false,
            .visible => utility.osk_update(1) catch {},
            .quit => utility.osk_shutdown_start() catch {},
            else => {},
        }

        display.wait_vblank_start() catch {};
        gfx.dialog_swap();
    }

    // PSP_UTILITY_OSK_RESULT_CANCELLED = 1
    if (osk_data.result == 1) return -1;
    return 0;
}
