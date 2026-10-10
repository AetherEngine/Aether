//! 3DS sockets: the entry starts the SOC service once; sessions only check it.
const std = @import("std");
const assert = std.debug.assert;
const zitrus = @import("zitrus");
const network = @import("../network.zig");

const horizon = zitrus.horizon;
const soc_buffer_len: usize = 1024 * 1024;

pub fn prepare() network.Error!void {
    if (service == null) return error.NetworkUnavailable;
}

pub fn release() void {}

pub fn configure_stream(_: std.Io.net.Stream, opts: network.StreamOptions) network.Error!void {
    _ = opts.no_delay orelse return;
    return error.UnsupportedOption;
}

var service: ?Service = null;

/// Starts the SOC service for std.Io sockets. Failure leaves networking off.
pub fn start(srv: horizon.ServiceManager, alloc: std.mem.Allocator) !void {
    assert(service == null);
    service = try Service.init(srv, alloc);
}

pub fn stop() void {
    if (service) |*ctx| ctx.deinit();
    service = null;
}

const Service = struct {
    soc: horizon.services.SocketUser,
    memory: horizon.MemoryBlock,
    buffer: []align(horizon.heap.page_size) u8,
    alloc: std.mem.Allocator,

    fn init(srv: horizon.ServiceManager, alloc: std.mem.Allocator) !Service {
        const soc = try horizon.services.SocketUser.open(srv);
        errdefer soc.close();

        const buffer = try alloc.alignedAlloc(u8, .fromByteUnits(horizon.heap.page_size), soc_buffer_len);
        errdefer alloc.free(buffer);

        const memory: horizon.MemoryBlock = try .create(buffer.ptr, buffer.len, .none, .rw);
        errdefer memory.close();

        try soc.sendInitialize(memory, buffer.len);
        errdefer soc.sendDeinitialize();

        try horizon.Io.global.initNetwork(.{ .soc = soc, .extra = .unowned });

        return .{
            .soc = soc,
            .memory = memory,
            .buffer = buffer,
            .alloc = alloc,
        };
    }

    fn deinit(self: *Service) void {
        defer self.* = undefined;

        horizon.Io.global.deinitNetwork();
        self.soc.sendDeinitialize();
        self.memory.close();
        self.alloc.free(self.buffer);
        self.soc.close();
    }
};
