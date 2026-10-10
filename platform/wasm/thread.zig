//! WASM/browser thread backend.
//!
//! Aether's browser runtime runs on one JS event-loop thread. The backend
//! satisfies the thread contract but fails thread creation explicitly, so
//! AetherIo runs `async` inline and reports `concurrent` unavailable.

const api = @import("../thread.zig");

pub const Handle = void;

pub fn spawn(cfg: api.Config, comptime func: anytype, args: anytype) !Handle {
    _ = cfg;
    _ = func;
    _ = args;
    return error.UnsupportedPlatform;
}

pub fn join(_: Handle) void {}

pub fn set_priority(_: Handle, _: api.Priority) anyerror!void {}

pub fn current_priority() api.Priority {
    return .normal;
}

pub fn change_current_priority(_: api.Priority) anyerror!i32 {
    return error.UnsupportedPlatform;
}

pub fn change_current_priority_by(_: i32) anyerror!i32 {
    return error.UnsupportedPlatform;
}

pub fn restore_current_priority(_: i32) anyerror!void {
    return error.UnsupportedPlatform;
}

pub fn cooperative_yield() void {}
