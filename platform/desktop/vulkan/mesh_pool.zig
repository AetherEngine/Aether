//! Mapped vertex/index storage. Drawn versions stay immutable until their
//! retirement fence completes; pages outlive meshes and are reused until shutdown.
const std = @import("std");
const assert = std.debug.assert;
const vk = @import("vulkan");
const Context = @import("context.zig");

const Pool = @This();
const page_bytes = 4 * 1024 * 1024;
const minimum_capacity = 256;
const alignment = 16;

pub const Region = struct { page: usize, offset: usize, capacity: usize };
const Range = struct { offset: usize, size: usize };

pub const MeshStorage = struct {
    region: ?Region = null,
    referenced: bool = false,
    index_offset: usize = 0,

    /// Returns the old drawn version for deferred retirement. Unreferenced
    /// versions can be reused even when no frames are being submitted.
    pub fn update(self: *MeshStorage, pool: *Pool, vertices: []const u8, indices: []const u8) !?Region {
        if (vertices.len == 0) return self.release(pool);
        const index_offset = std.mem.alignForward(usize, vertices.len, alignment);
        const needed = try std.math.add(usize, index_offset, indices.len);
        var retired: ?Region = null;
        if (self.region == null or self.referenced or self.region.?.capacity < needed) {
            const replacement = try pool.allocate(needed);
            retired = self.release(pool);
            self.region = replacement;
        }
        self.index_offset = index_offset;
        const dst = pool.bytes(self.region.?);
        @memcpy(dst[0..vertices.len], vertices);
        @memcpy(dst[index_offset..][0..indices.len], indices);
        return retired;
    }

    pub fn release(self: *MeshStorage, pool: *Pool) ?Region {
        const old = self.region;
        const referenced = self.referenced;
        self.* = .{};
        if (old) |region| {
            if (referenced) return region;
            pool.release(region);
        }
        return null;
    }
};

const Page = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: [*]u8,
    free: std.ArrayList(Range) = .empty,
    live: usize = 0,

    fn init(context: *Context, allocator: std.mem.Allocator, size: usize) !Page {
        const device = context.logical_device;
        const buffer = try device.createBuffer(&.{
            .size = size,
            .usage = .{ .vertex_buffer = true, .index_buffer = true },
            .sharing_mode = .exclusive,
        }, null);
        errdefer device.destroyBuffer(buffer, null);
        const requirements = device.getBufferMemoryRequirements(buffer);
        const memory = context.allocate_gpu_buffer(requirements, .{
            .host_visible = true,
            .host_coherent = true,
            .device_local = true,
        }) catch try context.allocate_gpu_buffer(requirements, .{
            .host_visible = true,
            .host_coherent = true,
        });
        errdefer device.freeMemory(memory, null);
        try device.bindBufferMemory(buffer, memory, 0);
        const mapped = try device.mapMemory(memory, 0, size, .{});
        errdefer device.unmapMemory(memory);
        var page: Page = .{ .buffer = buffer, .memory = memory, .mapped = @ptrCast(mapped) };
        try page.free.append(allocator, .{ .offset = 0, .size = size });
        return page;
    }

    fn deinit(self: *Page, context: *Context, allocator: std.mem.Allocator) void {
        context.logical_device.unmapMemory(self.memory);
        context.logical_device.destroyBuffer(self.buffer, null);
        context.logical_device.freeMemory(self.memory, null);
        self.free.deinit(allocator);
        self.* = undefined;
    }

    fn allocate(self: *Page, allocator: std.mem.Allocator, capacity: usize) !?usize {
        for (self.free.items, 0..) |range, i| {
            if (range.size < capacity) continue;
            // At most live + 1 free ranges can exist. Reserve the next bound
            // now so retirement never needs to allocate CPU memory.
            try self.free.ensureTotalCapacity(allocator, self.live + 2);
            if (range.size == capacity) {
                _ = self.free.orderedRemove(i);
            } else {
                self.free.items[i].offset += capacity;
                self.free.items[i].size -= capacity;
            }
            self.live += 1;
            return range.offset;
        }
        return null;
    }

    fn release(self: *Page, region: Region) void {
        assert(self.live > 0);
        var i: usize = 0;
        while (i < self.free.items.len and self.free.items[i].offset < region.offset) : (i += 1) {}
        if (i > 0) assert(self.free.items[i - 1].offset + self.free.items[i - 1].size <= region.offset);
        if (i < self.free.items.len) assert(region.offset + region.capacity <= self.free.items[i].offset);
        self.free.insertAssumeCapacity(i, .{ .offset = region.offset, .size = region.capacity });
        if (i > 0 and self.free.items[i - 1].offset + self.free.items[i - 1].size == region.offset) {
            self.free.items[i - 1].size += region.capacity;
            _ = self.free.orderedRemove(i);
            i -= 1;
        }
        if (i + 1 < self.free.items.len and self.free.items[i].offset + self.free.items[i].size == self.free.items[i + 1].offset) {
            self.free.items[i].size += self.free.items[i + 1].size;
            _ = self.free.orderedRemove(i + 1);
        }
        self.live -= 1;
    }
};

context: *Context,
allocator: std.mem.Allocator,
pages: std.ArrayList(Page) = .empty,

pub fn init(context: *Context, allocator: std.mem.Allocator) Pool {
    return .{ .context = context, .allocator = allocator };
}

pub fn deinit(self: *Pool) void {
    for (self.pages.items) |*page| page.deinit(self.context, self.allocator);
    self.pages.deinit(self.allocator);
    self.* = undefined;
}

pub fn allocate(self: *Pool, needed: usize) !Region {
    const capacity = try std.math.ceilPowerOfTwo(usize, @max(minimum_capacity, needed));
    for (self.pages.items, 0..) |*page, i| {
        if (try page.allocate(self.allocator, capacity)) |offset| {
            return .{ .page = i, .offset = offset, .capacity = capacity };
        }
    }
    try self.pages.ensureUnusedCapacity(self.allocator, 1);
    var page = try Page.init(self.context, self.allocator, @max(page_bytes, capacity));
    errdefer page.deinit(self.context, self.allocator);
    const offset = (try page.allocate(self.allocator, capacity)).?;
    self.pages.appendAssumeCapacity(page);
    return .{ .page = self.pages.items.len - 1, .offset = offset, .capacity = capacity };
}

pub fn release(self: *Pool, region: Region) void {
    self.pages.items[region.page].release(region);
}

pub fn get_buffer(self: *const Pool, region: Region) vk.Buffer {
    return self.pages.items[region.page].buffer;
}

pub fn bytes(self: *Pool, region: Region) []u8 {
    return self.pages.items[region.page].mapped[region.offset..][0..region.capacity];
}
