const std = @import("std");
const assert = std.debug.assert;
const sdk = @import("pspsdk");
const api = @import("../network_api.zig");
var references: u32 = 0;

pub fn prepare() api.Error!void {
    if (references == std.math.maxInt(u32)) return error.TooManySessions;
    if (references == 0) {
        try initialize();
        if (!@import("psp_dialogs.zig").show_net_dialog()) {
            sdk.extra.net.disconnect();
            sdk.extra.net.deinit();
            return error.NetworkUnavailable;
        }
    }
    references += 1;
}

fn initialize() api.Error!void {
    // The SDK marks initialization complete only after every stage succeeds.
    // Its deinit is a no-op before that point, so unwind successful stages here.
    sdk.extra.net.init() catch |err| {
        const completed: u8 = switch (err) {
            error.LoadCommonModule => 0,
            error.LoadInetModule => 1,
            error.NetInit => 2,
            error.InetInit => 3,
            error.ApctlInit => 4,
            error.ResolverInit => 5,
        };
        if (completed >= 5) sdk.net.apctl_term() catch {};
        if (completed >= 4) sdk.net.inet_term() catch {};
        if (completed >= 3) sdk.net.term() catch {};
        if (completed >= 2) sdk.utility.unload_net_module(.inet) catch {};
        if (completed >= 1) sdk.utility.unload_net_module(.common) catch {};
        return error.NetworkUnavailable;
    };
}

pub fn release() void {
    assert(references > 0);
    references -= 1;
    if (references == 0) {
        sdk.extra.net.disconnect();
        sdk.extra.net.deinit();
    }
}

pub fn configure_stream(stream: std.Io.net.Stream, opts: api.StreamOptions) api.Error!void {
    const enabled = opts.no_delay orelse return;
    sdk.extra.net.setTcpNoDelay(@intCast(stream.socket.handle), enabled) catch return error.ConfigureFailed;
}
