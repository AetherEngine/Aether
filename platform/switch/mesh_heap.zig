//! Mesh vertex and index storage carved out of a few large GPU-visible memory
//! blocks. One deko3d block per mesh hit Horizon's limit on live GPU mappings
//! (about 5100) once a 512x128x512 world loaded, and every block creation is
//! a kernel call.
const std = @import("std");
const assert = std.debug.assert;
const dk = @import("deko.zig");
const Context = @import("context.zig");

const page_size: u32 = 8 * 1024 * 1024;
/// Power-of-two size classes from 256 bytes to a whole page. Larger requests
/// get a block of their own.
const min_shift: u5 = 8;
const max_shift: u5 = 23;
const class_count = @as(u32, max_shift) - min_shift + 1;
const range_align: u32 = 256;
const frame_mask_bits = 3;
const block_flags = dk.MemCpuUncached | dk.MemGpuCached;

comptime {
    assert(@as(u32, 1) << max_shift == page_size);
}

pub const Range = struct {
    mem_block: dk.DkMemBlock = null,
    offset: u32 = 0,
    capacity: u32 = 0,
    /// Owns `mem_block` alone; destroyed on release instead of reused.
    dedicated: bool = false,

    pub fn gpu_addr(self: Range) dk.DkGpuAddr {
        return dk.dkMemBlockGetGpuAddr(self.mem_block) + self.offset;
    }

    pub fn cpu(self: Range) ?[*]u8 {
        const base: [*]u8 = @ptrCast(dk.dkMemBlockGetCpuAddr(self.mem_block) orelse return null);
        return base + self.offset;
    }
};

const Pending = struct { range: Range, frame_mask: u32 };

const MeshHeap = @This();

allocator: std.mem.Allocator,
context: *Context,
pages: std.ArrayList(dk.DkMemBlock) = .empty,
/// Next free offset in the newest page.
bump: u32 = page_size,
free_lists: [class_count]std.ArrayList(Range) = @splat(.empty),
/// Released ranges that frames still in flight may read.
pending: std.ArrayList(Pending) = .empty,

pub fn init(allocator: std.mem.Allocator, context: *Context) MeshHeap {
    return .{ .allocator = allocator, .context = context };
}

pub fn alloc(self: *MeshHeap, size: u32) !Range {
    assert(size > 0);
    if (size > page_size) {
        const mem = try self.context.create_mem_block(size, block_flags);
        return .{ .mem_block = mem, .capacity = dk.dkMemBlockGetSize(mem), .dedicated = true };
    }
    const needed_shift = std.math.log2_int_ceil(u32, size);
    const shift: u5 = if (needed_shift < min_shift) min_shift else @intCast(needed_shift);
    const class = shift - min_shift;
    if (self.free_lists[class].pop()) |range| return range;

    const capacity = @as(u32, 1) << shift;
    var offset = std.mem.alignForward(u32, self.bump, range_align);
    if (self.pages.items.len == 0 or offset + capacity > page_size) {
        try self.pages.ensureUnusedCapacity(self.allocator, 1);
        self.pages.appendAssumeCapacity(try self.context.create_mem_block(page_size, block_flags));
        offset = 0;
    }
    self.bump = offset + capacity;
    return .{ .mem_block = self.pages.items[self.pages.items.len - 1], .offset = offset, .capacity = capacity };
}

/// Release `range` once the frames in `frame_mask` complete.
pub fn free(self: *MeshHeap, range: Range, frame_mask: u32) void {
    if (range.mem_block == null) return;
    const mask = frame_mask & ((1 << frame_mask_bits) - 1);
    if (mask == 0) return self.release(range);
    self.pending.append(self.allocator, .{ .range = range, .frame_mask = mask }) catch {
        self.context.wait_idle("mesh heap deferred free fallback");
        self.release(range);
    };
}

/// Called when a frame's GPU work completes.
pub fn retire_frame(self: *MeshHeap, frame_index: usize) void {
    const bit = @as(u32, 1) << @intCast(frame_index % frame_mask_bits);
    var write: usize = 0;
    for (self.pending.items) |item| {
        const mask = item.frame_mask & ~bit;
        if (mask == 0) {
            self.release(item.range);
        } else {
            self.pending.items[write] = .{ .range = item.range, .frame_mask = mask };
            write += 1;
        }
    }
    self.pending.shrinkRetainingCapacity(write);
}

fn release(self: *MeshHeap, range: Range) void {
    if (range.dedicated) return dk.dkMemBlockDestroy(range.mem_block);
    const class = std.math.log2_int(u32, range.capacity) - min_shift;
    self.free_lists[class].append(self.allocator, range) catch {
        // The range is simply lost until the heap is torn down.
    };
}

/// The GPU must be idle.
pub fn deinit(self: *MeshHeap) void {
    defer self.* = undefined;

    for (self.pending.items) |item| {
        if (item.range.dedicated) dk.dkMemBlockDestroy(item.range.mem_block);
    }
    self.pending.deinit(self.allocator);
    for (&self.free_lists) |*list| list.deinit(self.allocator);
    for (self.pages.items) |page| dk.dkMemBlockDestroy(page);
    self.pages.deinit(self.allocator);
}
