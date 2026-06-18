//! Minimal `ir:rst` wrapper for New 3DS C-stick and ZL/ZR input.

const std = @import("std");
const zitrus = @import("zitrus");
const horizon = zitrus.horizon;
const tls = horizon.tls;
const ipc = horizon.ipc;

const IrRst = @This();
const ClientSession = horizon.Session.Client;
const ServiceManager = horizon.ServiceManager;

pub const service = "ir:rst";

pub const Pad = extern struct {
    pub const State = packed struct(u32) {
        _unused0: u14 = 0,
        zl: bool,
        zr: bool,
        _unused1: u8 = 0,
        c_stick_right: bool,
        c_stick_left: bool,
        c_stick_up: bool,
        c_stick_down: bool,
        _unused2: u4 = 0,
    };

    pub const CStickState = extern struct { x: i16, y: i16 };
    pub const Entry = extern struct { current: State, pressed: State, released: State, c_stick: CStickState };

    tick: u64,
    last_tick: u64,
    index: u32,
    _pad0: u32 = 0,
    entries: [8]Entry,
};

pub const Shared = extern struct {
    pad: Pad,
};

pub const Handles = struct {
    shm: horizon.MemoryBlock,
    ev: horizon.Event,

    pub fn close(handles: Handles) void {
        handles.shm.close();
        handles.ev.close();
    }
};

pub const Input = struct {
    handles: Handles,
    shm_memory_data: *align(horizon.heap.page_size) Shared,

    pub fn init(rst: IrRst) !Input {
        var handles = try rst.sendGetHandles();
        errdefer handles.close();

        const shm_memory_data = horizon.heap.allocShared(@sizeOf(Shared));
        try handles.shm.map(shm_memory_data, .r, .dont_care);

        return .{
            .handles = handles,
            .shm_memory_data = @ptrCast(shm_memory_data),
        };
    }

    pub fn deinit(input: *Input) void {
        input.handles.shm.unmap(@ptrCast(input.shm_memory_data));
        input.handles.close();
        input.* = undefined;
    }

    pub fn pollPad(input: Input) Pad.Entry {
        const pad: *const Pad = &input.shm_memory_data.pad;
        const index = @atomicLoad(u32, &pad.index, .acquire);
        return pad.entries[index];
    }
};

session: ClientSession,

pub fn open(srv: ServiceManager) !IrRst {
    return .{ .session = try srv.getService(service, .wait) };
}

pub fn close(rst: IrRst) void {
    rst.session.close();
}

pub fn sendGetHandles(rst: IrRst) !Handles {
    const data = tls.get();
    return switch ((try data.ipc.sendRequest(rst.session, command.GetHandles, .{}, .{})).cases()) {
        .success => |s| s.value.handles.wrapped,
        .failure => |code| horizon.unexpectedResult(code),
    };
}

pub fn sendInitialize(rst: IrRst, ms_update_period: u32, use_raw_c_stick: bool) !void {
    const data = tls.get();
    return switch ((try data.ipc.sendRequest(rst.session, command.Initialize, .{
        .ms_update_period = ms_update_period,
        .use_raw_c_stick = use_raw_c_stick,
    }, .{})).cases()) {
        .success => {},
        .failure => |code| horizon.unexpectedResult(code),
    };
}

pub fn sendShutdown(rst: IrRst) !void {
    const data = tls.get();
    return switch ((try data.ipc.sendRequest(rst.session, command.Shutdown, .{}, .{})).cases()) {
        .success => {},
        .failure => |code| horizon.unexpectedResult(code),
    };
}

pub const command = struct {
    pub const GetHandles = ipc.Command(Id, .get_handles, struct {}, struct { handles: ipc.HandleArray(Handles) });
    pub const Initialize = ipc.Command(Id, .initialize, struct { ms_update_period: u32, use_raw_c_stick: bool }, struct {});
    pub const Shutdown = ipc.Command(Id, .shutdown, struct {}, struct {});

    pub const Id = enum(u16) {
        get_handles = 0x0001,
        initialize,
        shutdown,
    };
};
