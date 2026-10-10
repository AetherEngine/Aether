//! Desktop sockets come from the process; sessions only configure streams.
const std = @import("std");
const options = @import("options");
const network = @import("../network.zig");

pub fn prepare() network.Error!void {}

pub fn release() void {}

pub fn configure_stream(stream: std.Io.net.Stream, opts: network.StreamOptions) network.Error!void {
    const enabled = opts.no_delay orelse return;
    switch (options.config.platform) {
        .linux, .macos => {
            const value: c_int = @intFromBool(enabled);
            const tcp_protocol = @field(@field(std.posix, "IPPROTO"), "TCP");
            const no_delay_option = @field(@field(std.posix, "TCP"), "NODELAY");
            std.posix.setsockopt(stream.socket.handle, tcp_protocol, no_delay_option, std.mem.asBytes(&value)) catch
                return error.ConfigureFailed;
        },
        // Zig's Windows I/O streams use AFD handles, not Winsock SOCKETs.
        // Do not pass those handles to setsockopt.
        else => return error.UnsupportedOption,
    }
}
