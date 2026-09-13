const std = @import("std");
const MeshPool = @import("mesh_pool.zig");
const Swapchain = @import("swapchain.zig");

const MaxFrames = Swapchain.frames_in_flight;

allocator: std.mem.Allocator,
buckets: [MaxFrames]std.ArrayList(MeshPool.Region) = @splat(.empty),
// The current recording frame, or the latest submitted frame between frames.
// Do not change this when acquisition fails or rendering is suspended.
frame_index: usize = 0,

const GarbageCollector = @This();

pub fn init(allocator: std.mem.Allocator) GarbageCollector {
    return .{ .allocator = allocator };
}

pub fn retire(self: *GarbageCollector, region: MeshPool.Region) !void {
    try self.buckets[self.frame_index].append(self.allocator, region);
}

pub fn collect(self: *GarbageCollector, pool: *MeshPool) void {
    // Called after waiting this slot's fence, before recording its next use.
    var list = &self.buckets[self.frame_index];
    for (list.items) |region| pool.release(region);
    list.clearRetainingCapacity();
}

pub fn deinit(self: *GarbageCollector) void {
    defer self.* = undefined;

    // The renderer waits for idle and destroys all pool pages at shutdown.
    for (&self.buckets) |*list| list.deinit(self.allocator);
}
