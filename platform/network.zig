//! Network-session contract and the target's session backend.
const options = @import("options");
const std = @import("std");
const contract = @import("contract.zig");
pub const Error = error{ UnsupportedPlatform, UnsupportedOption, NetworkUnavailable, ConfigureFailed, TooManySessions };
pub const StreamOptions = struct {
    /// Null preserves the socket's existing setting.
    no_delay: ?bool = null,
};

pub const Interface = struct {
    prepare: fn () Error!void,
    release: fn () void,
    configure_stream: fn (std.Io.net.Stream, StreamOptions) Error!void,
};

const Backend = @import("backend.zig").target.network;

comptime {
    contract.assert_impl("network", Backend, Interface);
}

/// Owns a platform network-session reference. Prepare/release on the app thread;
/// do not copy an active Session. Close its sockets before releasing it.
/// Preparation establishes local services, not remote reachability. PSP may
/// show a system dialog and requires initialized native graphics. Other native
/// backends borrow process socket services; release does not shut those down.
pub const Session = struct {
    active: bool = false,

    pub fn prepare() Error!Session {
        try Backend.prepare();
        return .{ .active = true };
    }

    pub fn release(self: *Session) void {
        if (!self.active) return;
        Backend.release();
        self.active = false;
    }

    pub fn configure_stream(self: *const Session, stream: std.Io.net.Stream, opts: StreamOptions) Error!void {
        if (!self.active) return error.NetworkUnavailable;
        try Backend.configure_stream(stream, opts);
    }
};

test "network session release is idempotent" {
    if (options.config.platform == .wasm or options.config.platform == .psp) return error.SkipZigTest;
    var session = try Session.prepare();
    session.release();
    session.release();
    try std.testing.expect(!session.active);
}
