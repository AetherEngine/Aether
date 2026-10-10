//! Switch sockets: the base Io starts libnx's socket service on first use;
//! the entry shuts it down at exit.
const std = @import("std");
const io = @import("io.zig");
const network = @import("../network.zig");

pub fn prepare() network.Error!void {
    io.ensure_networking() catch return error.NetworkUnavailable;
}

pub fn release() void {}

pub fn configure_stream(_: std.Io.net.Stream, opts: network.StreamOptions) network.Error!void {
    _ = opts.no_delay orelse return;
    return error.UnsupportedOption;
}
