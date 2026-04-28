//! Switch thread backend stub.
//!
//! Real implementation will wrap libnx's `threadCreate`/`threadStart`/
//! `threadWaitForExit`. Until then `spawn` returns `error.Unsupported`
//! so callers fail fast instead of silently returning a bogus handle.

const std = @import("std");
const api = @import("../thread_api.zig");

pub const Handle = u32;

pub fn spawn(cfg: api.Config, comptime func: anytype, args: anytype) !Handle {
    _ = cfg;
    _ = func;
    _ = args;
    return error.Unsupported;
}

pub fn join(_: Handle) void {}

pub fn set_priority(_: Handle, _: api.Priority) anyerror!void {}

pub fn current_priority() api.Priority {
    return .normal;
}
