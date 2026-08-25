const std = @import("std");
const assert = std.debug.assert;

pub fn HandleType(comptime Tag: type) type {
    return packed struct(u32) {
        const Handle = @This();

        index: u24 = 0,
        generation: u8 = 0,

        pub const TagType = Tag;
        pub const none: Handle = .{};

        pub fn from_index(index: usize, generation: u8) Handle {
            assert(index <= std.math.maxInt(u24));
            return .{
                .index = @intCast(index),
                .generation = generation,
            };
        }

        pub fn is_null(self: Handle) bool {
            return self.index == 0;
        }

        pub fn raw_index(self: Handle) usize {
            return self.index;
        }
    };
}

/// Fixed-size sparse resource table with generational typed handles.
///
/// Slot 0 is reserved for the null handle. A removed slot increments its
/// generation before it can be reused, so old handles fail validation instead
/// of silently naming the new occupant.
pub fn ResourceTableType(comptime T: type, comptime SIZE: usize, comptime H: type) type {
    comptime {
        if (SIZE < 2)
            @compileError("SIZE must be >= 2 (index 0 is reserved as the null handle).");
        if (@sizeOf(H) != @sizeOf(u32) or !@hasDecl(H, "from_index"))
            @compileError("H must be a Util.Handle instantiation.");
    }

    return struct {
        const ResourceTable = @This();

        slots: [SIZE]?T = undefined,
        generations: [SIZE]u8 = undefined,
        head: usize = 1,
        count: usize = 0,

        pub fn init() ResourceTable {
            return .{
                .slots = @splat(null),
                .generations = @splat(1),
                .head = 1,
                .count = 0,
            };
        }

        pub fn clear(self: *ResourceTable) void {
            for (1..SIZE) |i| {
                if (self.slots[i] != null) {
                    self.bump_generation(i);
                }
            }
            self.slots = @splat(null);
            self.head = 1;
            self.count = 0;
        }

        pub fn len(self: *const ResourceTable) usize {
            return self.count;
        }

        pub fn capacity(self: *const ResourceTable) usize {
            _ = self;
            return SIZE - 1;
        }

        pub fn is_full(self: *const ResourceTable) bool {
            return self.count == self.capacity();
        }

        pub fn add(self: *ResourceTable, value: T) ?H {
            if (self.is_full()) return null;

            var idx = self.head;
            for (0..self.capacity()) |_| {
                if (self.slots[idx] == null) {
                    self.slots[idx] = value;
                    self.count += 1;
                    self.head = next_index(idx);
                    return H.from_index(idx, self.generations[idx]);
                }
                idx = next_index(idx);
            }
            return null;
        }

        pub fn remove(self: *ResourceTable, handle: H) bool {
            const idx = self.valid_index(handle) orelse return false;
            self.slots[idx] = null;
            if (self.count > 0) self.count -= 1;
            self.bump_generation(idx);
            if (idx < self.head) self.head = idx;
            return true;
        }

        pub fn get(self: *const ResourceTable, handle: H) ?T {
            const idx = self.valid_index(handle) orelse return null;
            return self.slots[idx];
        }

        pub fn get_ptr(self: *ResourceTable, handle: H) ?*T {
            const idx = self.valid_index(handle) orelse return null;
            if (self.slots[idx]) |*value| return value;
            return null;
        }

        pub fn update(self: *ResourceTable, handle: H, value: T) bool {
            const ptr = self.get_ptr(handle) orelse return false;
            ptr.* = value;
            return true;
        }

        pub fn raw_index(self: *const ResourceTable, handle: H) ?usize {
            return self.valid_index(handle);
        }

        fn valid_index(self: *const ResourceTable, handle: H) ?usize {
            const idx = handle.raw_index();
            if (idx == 0 or idx >= SIZE) return null;
            if (self.generations[idx] != handle.generation) return null;
            if (self.slots[idx] == null) return null;
            return idx;
        }

        fn bump_generation(self: *ResourceTable, idx: usize) void {
            self.generations[idx] +%= 1;
            if (self.generations[idx] == 0) self.generations[idx] = 1;
        }

        inline fn next_index(i: usize) usize {
            var n = (i + 1) % SIZE;
            if (n == 0) n = 1;
            return n;
        }
    };
}

test "resource table rejects stale handles after slot reuse" {
    const TextureTag = enum {};
    const TextureHandle = HandleType(TextureTag);
    const Table = ResourceTableType(u32, 3, TextureHandle);

    var table = Table.init();
    const first = table.add(10) orelse return error.TestExpectedNonNull;
    try std.testing.expectEqual(@as(?u32, 10), table.get(first));
    try std.testing.expect(table.remove(first));
    try std.testing.expect(table.get(first) == null);

    const second = table.add(20) orelse return error.TestExpectedNonNull;
    try std.testing.expectEqual(first.raw_index(), second.raw_index());
    try std.testing.expect(first.generation != second.generation);
    try std.testing.expect(table.get(first) == null);
    try std.testing.expectEqual(@as(?u32, 20), table.get(second));
}
