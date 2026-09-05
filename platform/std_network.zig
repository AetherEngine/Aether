const std = @import("std");
const options = @import("options");
const api = @import("network_api.zig");

pub fn prepare() api.Error!void {
    switch (options.config.platform) {
        .wasm => return error.UnsupportedPlatform,
        .nintendo_3ds => if (!@import("3ds/app.zig").network_available()) return error.NetworkUnavailable,
        .nintendo_switch => @import("c_io.zig").ensureNetworking() catch return error.NetworkUnavailable,
        else => {},
    }
}

pub fn release() void {}

pub fn configure_stream(stream: std.Io.net.Stream, opts: api.StreamOptions) api.Error!void {
    if (options.config.platform == .wasm) return error.UnsupportedPlatform;
    const enabled = opts.no_delay orelse return;
    switch (options.config.platform) {
        .linux, .macos => {
            const value: c_int = @intFromBool(enabled);
            const tcp_protocol = @field(@field(std.posix, "IPPROTO"), "TCP");
            const no_delay_option = @field(@field(std.posix, "TCP"), "NODELAY");
            std.posix.setsockopt(stream.socket.handle, tcp_protocol, no_delay_option, std.mem.asBytes(&value)) catch return error.ConfigureFailed;
        },
        // Zig's Windows I/O streams use AFD handles, not Winsock SOCKETs.
        // Do not pass those handles to setsockopt.
        else => return error.UnsupportedOption,
    }
}
