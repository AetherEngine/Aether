//! Browsers expose no stream sockets to WASM.
const std = @import("std");
const network = @import("../network.zig");

pub fn prepare() network.Error!void {
    return error.UnsupportedPlatform;
}

pub fn release() void {}

pub fn configure_stream(_: std.Io.net.Stream, _: network.StreamOptions) network.Error!void {
    return error.UnsupportedPlatform;
}
