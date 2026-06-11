const std = @import("std");
const dk = @import("deko.zig");
const Context = @import("context.zig");

const MAX_FRAMES = 3;

const GcItem = union(enum) {
    mem_block: *dk.DkMemBlock_T,
};

allocator: std.mem.Allocator,
context: *Context,
buckets: [MAX_FRAMES]std.ArrayList(GcItem) = .{ .empty, .empty, .empty },
frame_index: usize = 0,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, context: *Context) Self {
    return .{ .allocator = allocator, .context = context };
}

pub fn deferDestroyMemBlock(self: *Self, mem_block: dk.DkMemBlock) !void {
    const ptr = mem_block orelse return;
    try self.buckets[self.frame_index].append(self.allocator, .{ .mem_block = ptr });
}

pub fn collect(self: *Self) void {
    var list = &self.buckets[self.frame_index];
    for (list.items) |item| switch (item) {
        .mem_block => |mem| dk.dkMemBlockDestroy(mem),
    };
    list.clearRetainingCapacity();
}

pub fn collectAll(self: *Self) void {
    for (&self.buckets) |*list| {
        for (list.items) |item| switch (item) {
            .mem_block => |mem| dk.dkMemBlockDestroy(mem),
        };
        list.clearRetainingCapacity();
    }
}

pub fn deinit(self: *Self) void {
    self.context.waitIdle("switch gc deinit");
    for (&self.buckets) |*list| {
        for (list.items) |item| switch (item) {
            .mem_block => |mem| dk.dkMemBlockDestroy(mem),
        };
        list.deinit(self.allocator);
    }
}
