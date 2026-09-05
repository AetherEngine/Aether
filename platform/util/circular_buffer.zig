const std = @import("std");
const testing = std.testing;

/// Circular, opportunistic insertion into a fixed-size sparse table.
/// Index 0 is permanently reserved as a null handle.
pub fn CircularBufferType(comptime T: type, comptime slot_count: usize) type {
    comptime {
        if (slot_count < 2)
            @compileError("slot_count must be >= 2 (index 0 is reserved as the null handle).");
    }

    return struct {
        const CircularBuffer = @This();

        buffer: [slot_count]?T = undefined,
        head: usize = 1,
        count: usize = 0,

        pub fn init() CircularBuffer {
            return .{
                .buffer = @splat(null),
            };
        }

        pub fn clear(self: *CircularBuffer) void {
            self.buffer = @splat(null);
            self.head = 1;
            self.count = 0;
        }

        pub fn len(self: *const CircularBuffer) usize {
            return self.count;
        }

        pub fn capacity(_: *const CircularBuffer) usize {
            return slot_count - 1;
        }

        pub fn is_full(self: *const CircularBuffer) bool {
            return self.count == self.capacity();
        }

        fn next_index(i: usize) usize {
            return if (i + 1 == slot_count) 1 else i + 1;
        }

        /// Inserts value into the first empty slot encountered by circular probing.
        /// Returns the assigned handle (index in [1..slot_count-1]) or null if full.
        pub fn add_element(self: *CircularBuffer, value: T) ?usize {
            if (self.is_full()) return null;

            var idx = self.head;
            for (0..self.capacity()) |_| {
                if (self.buffer[idx] == null) {
                    self.buffer[idx] = value;
                    self.count += 1;
                    self.head = next_index(idx);
                    return idx;
                }
                idx = next_index(idx);
            }
            return null;
        }

        pub fn update_element(self: *CircularBuffer, index: usize, value: T) void {
            if (index == 0 or index >= slot_count) return;

            if (self.buffer[index]) |*v| {
                v.* = value;
            }
        }

        /// Removes the element at `index` (handle). Returns true if something was removed.
        pub fn remove_element(self: *CircularBuffer, index: usize) bool {
            if (index == 0 or index >= slot_count) return false;
            if (self.buffer[index] != null) {
                self.buffer[index] = null;
                self.count -= 1;
                // Prefer to restart probing near the earliest gap.
                if (index < self.head) self.head = index;
                return true;
            }
            return false;
        }

        pub fn get_element(self: *const CircularBuffer, index: usize) ?T {
            if (index == 0 or index >= slot_count) return null;
            return self.buffer[index];
        }

        pub fn get_element_ptr(self: *CircularBuffer, index: usize) ?*T {
            if (index == 0 or index >= slot_count) return null;
            if (self.buffer[index]) |*value| return value;
            return null;
        }
    };
}

test "init/clear/capacity basics" {
    const Buf = CircularBufferType(u32, 5);
    var b = Buf.init();

    try testing.expectEqual(@as(usize, 0), b.len());
    try testing.expect(!b.is_full());
    try testing.expectEqual(@as(usize, 4), b.capacity());

    try testing.expect(b.get_element(0) == null);
    try testing.expect(b.get_element(5) == null);

    for (1..5) |i| try testing.expect(b.get_element(i) == null);

    b.clear();
    try testing.expectEqual(@as(usize, 0), b.len());
    try testing.expect(b.get_element(0) == null);
    for (1..5) |i| try testing.expect(b.get_element(i) == null);
}

test "sequential inserts skip 0 and return handles" {
    const Buf = CircularBufferType(u32, 5);
    var b = Buf.init();

    const h1 = b.add_element(10) orelse return error.TestExpectedNonNull;
    const h2 = b.add_element(20) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(usize, 1), h1);
    try testing.expectEqual(@as(usize, 2), h2);

    try testing.expectEqual(@as(?u32, 10), b.get_element(h1));
    try testing.expectEqual(@as(?u32, 20), b.get_element(h2));

    try testing.expectEqual(@as(usize, 2), b.len());
}

test "fills to capacity then rejects, remove reuses hole by circular probe" {
    const Buf = CircularBufferType(u32, 5);
    var b = Buf.init();

    const h1 = b.add_element(1) orelse return error.TestExpectedNonNull;
    const h2 = b.add_element(2) orelse return error.TestExpectedNonNull;
    const h3 = b.add_element(3) orelse return error.TestExpectedNonNull;
    const h4 = b.add_element(4) orelse return error.TestExpectedNonNull;
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4 }, &.{ h1, h2, h3, h4 });

    try testing.expect(b.is_full());
    try testing.expect(b.add_element(99) == null);

    try testing.expect(b.remove_element(h2));
    try testing.expectEqual(@as(usize, 3), b.len());
    try testing.expect(b.get_element(h2) == null);

    const h5 = b.add_element(5) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(h2, h5);
    try testing.expectEqual(@as(?u32, 5), b.get_element(h5));
    try testing.expect(b.is_full());
}

test "remove edge cases and bounds" {
    const Buf = CircularBufferType(u32, 4);
    var b = Buf.init();

    try testing.expect(!b.remove_element(0));
    try testing.expect(!b.remove_element(99));
    try testing.expect(!b.remove_element(3));

    const h = b.add_element(7) orelse return error.TestExpectedNonNull;
    try testing.expect(b.remove_element(h));
    try testing.expect(!b.remove_element(h));
    try testing.expectEqual(@as(usize, 0), b.len());
}

test "minimum valid size (SIZE=2) works: one usable slot at index 1" {
    const Buf = CircularBufferType(u32, 2);
    var b = Buf.init();

    const h1 = b.add_element(111) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(usize, 1), h1);
    try testing.expect(b.is_full());
    try testing.expect(b.add_element(222) == null);

    try testing.expect(b.remove_element(1));
    try testing.expect(!b.is_full());
    const h2 = b.add_element(222) orelse return error.TestExpectedNonNull;
    try testing.expectEqual(@as(usize, 1), h2);
    try testing.expectEqual(@as(?u32, 222), b.get_element(1));
}
