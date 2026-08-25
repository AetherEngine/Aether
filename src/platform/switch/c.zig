const options = @import("options");

const imported = @cImport({
    @cUndef("_GNU_SOURCE");
    @cUndef("_DEFAULT_SOURCE");
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("wint_t", "__WINT_TYPE__");

    switch (options.config.platform) {
        .nintendo_switch => {
            @cDefine("__SWITCH__", "1");
            @cDefine("__thread", "");
        },
        else => @compileError("platform/nintendo_c.zig is only wired for Nintendo targets"),
    }

    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/iosupport.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
    @cInclude("sys/socket.h");
    @cInclude("netinet/in.h");
    @cInclude("arpa/inet.h");
    @cInclude("netdb.h");
    @cInclude("poll.h");
    @cInclude("unistd.h");
    @cInclude("malloc.h");
    @cInclude("stdio.h");

    switch (options.config.platform) {
        .nintendo_switch => {
            @cInclude("switch/types.h");
        },
        else => unreachable,
    }
});

pub const c = imported;
pub const switch_c = SwitchC;

const SwitchC = struct {
    pub const s8 = imported.s8;
    pub const s32 = imported.s32;
    pub const s64 = imported.s64;
    pub const Result = imported.Result;
    pub const Handle = imported.Handle;
    pub const ThreadFunc = imported.ThreadFunc;
    pub const memalign = imported.memalign;
    pub const malloc = imported.malloc;
    pub const free = imported.free;

    pub const Thread = extern struct {
        handle: imported.Handle,
        owns_stack_mem: bool,
        stack_mem: ?*anyopaque,
        stack_mirror: ?*anyopaque,
        stack_sz: usize,
        tls_array: ?*?*anyopaque,
        next: ?*Thread,
        prev_next: ?*?*Thread,
    };

    pub const AppletOperationMode = c_uint;
    pub const AppletOperationMode_Handheld: AppletOperationMode = 0;
    pub const AppletOperationMode_Console: AppletOperationMode = 1;

    pub const HidAnalogStickState = extern struct {
        x: imported.s32,
        y: imported.s32,
    };

    pub const HidTouchState = extern struct {
        delta_time: imported.u64,
        attributes: imported.u32,
        finger_id: imported.u32,
        x: imported.u32,
        y: imported.u32,
        diameter_x: imported.u32,
        diameter_y: imported.u32,
        rotation_angle: imported.u32,
        reserved: imported.u32,
    };

    pub const HidTouchScreenState = extern struct {
        sampling_number: imported.u64,
        count: imported.s32,
        reserved: imported.u32,
        touches: [16]HidTouchState,
    };

    pub const PadState = extern struct {
        id_mask: imported.u8,
        active_id_mask: imported.u8,
        read_handheld: bool,
        active_handheld: bool,
        style_set: imported.u32,
        attributes: imported.u32,
        buttons_cur: imported.u64,
        buttons_old: imported.u64,
        sticks: [2]HidAnalogStickState,
        gc_triggers: [2]imported.u32,
    };

    pub const HidLaControllerSupportArgHeader = extern struct {
        player_count_min: imported.s8,
        player_count_max: imported.s8,
        enable_take_over_connection: imported.u8,
        enable_left_justify: imported.u8,
        enable_permit_joy_dual: imported.u8,
        enable_single_mode: imported.u8,
        enable_identification_color: imported.u8,
    };

    pub const HidLaControllerSupportArgColor = extern struct {
        r: imported.u8,
        g: imported.u8,
        b: imported.u8,
        a: imported.u8,
    };

    pub const HidLaControllerSupportArg = extern struct {
        hdr: HidLaControllerSupportArgHeader,
        identification_color: [8]HidLaControllerSupportArgColor,
        enable_explain_text: imported.u8,
        explain_text: [8][0x81]u8,
    };

    pub const HidLaControllerSupportResultInfo = extern struct {
        player_count: imported.s8,
        pad: [3]imported.u8,
        selected_id: imported.u32,
    };

    pub const AudioOutBuffer = extern struct {
        next: ?*AudioOutBuffer,
        buffer: ?*anyopaque,
        buffer_size: imported.u64,
        data_size: imported.u64,
        data_offset: imported.u64,
    };

    pub const HidNpadStyleTag_NpadFullKey: imported.u32 = 1 << 0;
    pub const HidNpadStyleTag_NpadHandheld: imported.u32 = 1 << 1;
    pub const HidNpadStyleTag_NpadJoyDual: imported.u32 = 1 << 2;
    pub const HidNpadStyleTag_NpadJoyLeft: imported.u32 = 1 << 3;
    pub const HidNpadStyleTag_NpadJoyRight: imported.u32 = 1 << 4;

    pub const HidNpadIdType_No1: imported.u32 = 0;
    pub const HidNpadIdType_Handheld: imported.u32 = 0x20;

    pub const HidNpadButton_A: imported.u64 = 1 << 0;
    pub const HidNpadButton_B: imported.u64 = 1 << 1;
    pub const HidNpadButton_X: imported.u64 = 1 << 2;
    pub const HidNpadButton_Y: imported.u64 = 1 << 3;
    pub const HidNpadButton_StickL: imported.u64 = 1 << 4;
    pub const HidNpadButton_StickR: imported.u64 = 1 << 5;
    pub const HidNpadButton_L: imported.u64 = 1 << 6;
    pub const HidNpadButton_R: imported.u64 = 1 << 7;
    pub const HidNpadButton_ZL: imported.u64 = 1 << 8;
    pub const HidNpadButton_ZR: imported.u64 = 1 << 9;
    pub const HidNpadButton_Plus: imported.u64 = 1 << 10;
    pub const HidNpadButton_Minus: imported.u64 = 1 << 11;
    pub const HidNpadButton_Left: imported.u64 = 1 << 12;
    pub const HidNpadButton_Up: imported.u64 = 1 << 13;
    pub const HidNpadButton_Right: imported.u64 = 1 << 14;
    pub const HidNpadButton_Down: imported.u64 = 1 << 15;
    pub const HidNpadButton_LeftSL: imported.u64 = 1 << 24;
    pub const HidNpadButton_LeftSR: imported.u64 = 1 << 25;
    pub const HidNpadButton_RightSL: imported.u64 = 1 << 26;
    pub const HidNpadButton_RightSR: imported.u64 = 1 << 27;

    pub const JOYSTICK_MAX: imported.s32 = 0x7FFF;

    pub extern fn threadCreate(t: *Thread, entry: imported.ThreadFunc, arg: ?*anyopaque, stack_mem: ?*anyopaque, stack_sz: usize, prio: c_int, cpuid: c_int) imported.Result;
    pub extern fn threadStart(t: *Thread) imported.Result;
    pub extern fn threadWaitForExit(t: *Thread) imported.Result;
    pub extern fn threadClose(t: *Thread) imported.Result;
    pub extern fn threadGetCurHandle() imported.Handle;

    pub extern fn fsdevMountSdmc() imported.Result;
    pub extern fn fsdevUnmountDevice(name: [*:0]const u8) c_int;
    pub extern fn romfsMountSelf(name: [*:0]const u8) imported.Result;
    pub extern fn romfsUnmount(name: [*:0]const u8) imported.Result;

    pub extern fn socketInitialize(config: ?*const anyopaque) imported.Result;
    pub extern fn socketExit() void;

    pub extern fn svcGetSystemTick() imported.u64;
    pub extern fn svcSleepThread(nano: imported.s64) void;
    pub extern fn svcGetThreadPriority(priority: *imported.s32, handle: imported.Handle) imported.Result;
    pub extern fn svcSetThreadPriority(handle: imported.Handle, priority: imported.u32) imported.Result;

    pub extern fn appletMainLoop() bool;
    pub extern fn appletGetOperationMode() AppletOperationMode;

    pub extern fn hidInitialize() imported.Result;
    pub extern fn hidExit() void;
    pub extern fn hidInitializeTouchScreen() void;
    pub extern fn hidGetTouchScreenStates(states: [*]HidTouchScreenState, count: usize) usize;

    pub extern fn padConfigureInput(max_players: imported.u32, style_set: imported.u32) void;
    pub extern fn padInitializeWithMask(pad: *PadState, mask: imported.u64) void;
    pub extern fn padUpdate(pad: *PadState) void;

    pub extern fn hidLaCreateControllerSupportArg(arg: *HidLaControllerSupportArg) void;
    pub extern fn hidLaShowControllerSupport(result_info: *HidLaControllerSupportResultInfo, arg: *const HidLaControllerSupportArg) imported.Result;

    pub extern fn swkbdCreate(config: ?*anyopaque, max_dictwords: imported.s32) imported.Result;
    pub extern fn swkbdClose(config: ?*anyopaque) void;
    pub extern fn swkbdConfigMakePresetDefault(config: ?*anyopaque) void;
    pub extern fn swkbdConfigSetOkButtonText(config: ?*anyopaque, str: [*:0]const u8) void;
    pub extern fn swkbdConfigSetHeaderText(config: ?*anyopaque, str: [*:0]const u8) void;
    pub extern fn swkbdConfigSetGuideText(config: ?*anyopaque, str: [*:0]const u8) void;
    pub extern fn swkbdConfigSetInitialText(config: ?*anyopaque, str: [*:0]const u8) void;
    pub extern fn swkbdShow(config: ?*anyopaque, out_string: [*:0]u8, out_string_size: usize) imported.Result;

    pub extern fn audoutInitialize() imported.Result;
    pub extern fn audoutExit() void;
    pub extern fn audoutStartAudioOut() imported.Result;
    pub extern fn audoutStopAudioOut() imported.Result;
    pub extern fn audoutAppendAudioOutBuffer(buffer: *AudioOutBuffer) imported.Result;
    pub extern fn audoutGetReleasedAudioOutBuffer(buffer: *?*AudioOutBuffer, released_count: *imported.u32) imported.Result;
};
