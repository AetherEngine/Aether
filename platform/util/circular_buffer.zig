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
