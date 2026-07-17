const std = @import("std");
const dk = @import("deko.zig");
const Context = @import("context.zig");

const MAX_FRAMES = 3;

const SharedItem = struct {
    mem_block: dk.DkMemBlock,
    pending_frame_mask: u32,
};

allocator: std.mem.Allocator,
context: *Context,
shared: std.ArrayList(SharedItem) = .empty,
frame_index: usize = 0,
completed_frames: u64 = 0,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, context: *Context) Self {
    return .{ .allocator = allocator, .context = context };
}

pub fn defer_destroy_mem_block_after_frame_mask(self: *Self, pending_frame_mask: u32, mem_block: dk.DkMemBlock) !void {
    const ptr = mem_block orelse return;
    if ((pending_frame_mask & ((1 << MAX_FRAMES) - 1)) == 0) {
        dk.dkMemBlockDestroy(ptr);
        return;
    }
    try self.shared.append(self.allocator, .{
        .mem_block = ptr,
        .pending_frame_mask = pending_frame_mask & ((1 << MAX_FRAMES) - 1),
    });
}

pub fn retire_frame(self: *Self, frame_index: usize, was_submitted: bool) void {
    self.frame_index = frame_index % MAX_FRAMES;
    if (was_submitted) self.completed_frames += 1;
    const retired_bit: u32 = @as(u32, 1) << @intCast(self.frame_index);
    var write: usize = 0;
    for (self.shared.items) |item| {
        const pending = item.pending_frame_mask & ~retired_bit;
        if (pending == 0) {
            dk.dkMemBlockDestroy(item.mem_block);
        } else {
            self.shared.items[write] = .{
                .mem_block = item.mem_block,
                .pending_frame_mask = pending,
            };
            write += 1;
        }
    }
    self.shared.shrinkRetainingCapacity(write);
}

pub fn collect_all(self: *Self) void {
    for (self.shared.items) |item| {
        dk.dkMemBlockDestroy(item.mem_block);
    }
    self.shared.clearRetainingCapacity();
}

pub fn deinit(self: *Self) void {
    self.context.wait_idle("switch gc deinit");
    for (self.shared.items) |item| {
        dk.dkMemBlockDestroy(item.mem_block);
    }
    self.shared.deinit(self.allocator);
}
