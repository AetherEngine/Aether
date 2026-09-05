const options = @import("options");
const std = @import("std");
pub const api = @import("network_api.zig");
pub const Error = api.Error;
pub const StreamOptions = api.StreamOptions;
const Backend = if (options.config.platform == .psp) @import("psp/network.zig") else @import("std_network.zig");

comptime {
    @import("contract.zig").assert_impl("network", Backend, api.Interface);
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
