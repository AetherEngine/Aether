const std = @import("std");
const dk = @import("deko.zig");
const Context = @import("context.zig");

const MAX_FRAMES = 3;

const GcItem = union(enum) {
    mem_block: *dk.DkMemBlock_T,
};

const SharedItem = struct {
    mem_block: *dk.DkMemBlock_T,
    retire_after_completed_frames: u64,
};

allocator: std.mem.Allocator,
context: *Context,
buckets: [MAX_FRAMES]std.ArrayList(GcItem) = .{ .empty, .empty, .empty },
shared: std.ArrayList(SharedItem) = .empty,
frame_index: usize = 0,
completed_frames: u64 = 0,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, context: *Context) Self {
    return .{ .allocator = allocator, .context = context };
}

pub fn deferDestroyMemBlock(self: *Self, mem_block: dk.DkMemBlock) !void {
    try self.deferDestroyMemBlockForFrame(self.frame_index, mem_block);
}

pub fn deferDestroyMemBlockForFrame(self: *Self, frame_index: usize, mem_block: dk.DkMemBlock) !void {
    const ptr = mem_block orelse return;
    try self.buckets[frame_index % MAX_FRAMES].append(self.allocator, .{ .mem_block = ptr });
}

pub fn deferDestroyMemBlockAfterAllFrames(self: *Self, mem_block: dk.DkMemBlock) !void {
    const ptr = mem_block orelse return;
    try self.shared.append(self.allocator, .{
        .mem_block = ptr,
        .retire_after_completed_frames = self.completed_frames + MAX_FRAMES,
    });
}

pub fn retireFrame(self: *Self, frame_index: usize, was_submitted: bool) void {
    self.frame_index = frame_index % MAX_FRAMES;
    if (was_submitted) self.completed_frames += 1;
    self.collectFrameBucket(self.frame_index);
    self.collectShared();
}

fn collectFrameBucket(self: *Self, frame_index: usize) void {
    var list = &self.buckets[frame_index % MAX_FRAMES];
    for (list.items) |item| switch (item) {
        .mem_block => |mem| dk.dkMemBlockDestroy(mem),
    };
    list.clearRetainingCapacity();
}

fn collectShared(self: *Self) void {
    var write: usize = 0;
    for (self.shared.items) |item| {
        if (item.retire_after_completed_frames <= self.completed_frames) {
            dk.dkMemBlockDestroy(item.mem_block);
        } else {
            self.shared.items[write] = item;
            write += 1;
        }
    }
    self.shared.shrinkRetainingCapacity(write);
}

pub fn collect(self: *Self) void {
    var list = &self.buckets[self.frame_index];
    for (list.items) |item| switch (item) {
        .mem_block => |mem| dk.dkMemBlockDestroy(mem),
    };
    list.clearRetainingCapacity();
    self.collectShared();
}

pub fn collectAll(self: *Self) void {
    for (&self.buckets) |*list| {
        for (list.items) |item| switch (item) {
            .mem_block => |mem| dk.dkMemBlockDestroy(mem),
        };
        list.clearRetainingCapacity();
    }
    for (self.shared.items) |item| {
        dk.dkMemBlockDestroy(item.mem_block);
    }
    self.shared.clearRetainingCapacity();
}

pub fn deinit(self: *Self) void {
    self.context.waitIdle("switch gc deinit");
    for (&self.buckets) |*list| {
        for (list.items) |item| switch (item) {
            .mem_block => |mem| dk.dkMemBlockDestroy(mem),
        };
        list.deinit(self.allocator);
    }
    for (self.shared.items) |item| {
        dk.dkMemBlockDestroy(item.mem_block);
    }
    self.shared.deinit(self.allocator);
}
