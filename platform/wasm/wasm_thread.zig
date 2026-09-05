//! WASM/browser thread backend.
//!
//! Aether's current browser runtime runs on one JS event-loop thread. Expose a
//! real backend type so generic code can name `Util.Thread`, but fail thread
//! creation explicitly.

const api = @import("../thread_api.zig");

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
