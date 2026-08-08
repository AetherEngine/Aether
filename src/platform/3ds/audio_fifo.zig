//! Lock-free single-producer/single-consumer byte FIFO used by the 3DS audio
//! streaming worker. The producer is the filesystem worker and the consumer
//! is the real-time mixer thread.

const std = @import("std");

pub const ByteFifo = struct {
    bytes: []u8,
    read_count: std.atomic.Value(usize) = .init(0),
    write_count: std.atomic.Value(usize) = .init(0),

    pub fn init(bytes: []u8) ByteFifo {
        std.debug.assert(bytes.len > 0);
        return .{ .bytes = bytes };
    }

    pub fn reset(self: *ByteFifo) void {
        // Reset only while both endpoints have stopped using the FIFO.
        self.read_count.store(0, .release);
        self.write_count.store(0, .release);
    }

    /// Drops all currently queued data. Call only from the consumer thread;
    /// unlike `reset`, this remains safe while the producer is active.
    pub fn discard_all(self: *ByteFifo) void {
        const write_pos = self.write_count.load(.acquire);
        self.read_count.store(write_pos, .release);
    }

    pub fn capacity(self: *const ByteFifo) usize {
        return self.bytes.len;
    }

    /// Bytes currently available to the consumer.
    pub fn readable(self: *const ByteFifo) usize {
        const write_pos = self.write_count.load(.acquire);
        const read_pos = self.read_count.load(.monotonic);
        const count = write_pos -% read_pos;
        std.debug.assert(count <= self.bytes.len);
        return count;
    }

    /// Bytes currently available to the producer.
    pub fn writable(self: *const ByteFifo) usize {
        const read_pos = self.read_count.load(.acquire);
        const write_pos = self.write_count.load(.monotonic);
        const used = write_pos -% read_pos;
        std.debug.assert(used <= self.bytes.len);
        return self.bytes.len - used;
    }

    /// Copies as much of `src` as fits and returns the copied byte count.
    /// Call only from the one producer thread.
    pub fn write(self: *ByteFifo, src: []const u8) usize {
        const write_pos = self.write_count.load(.monotonic);
        const read_pos = self.read_count.load(.acquire);
        const used = write_pos -% read_pos;
        std.debug.assert(used <= self.bytes.len);

        const n = @min(src.len, self.bytes.len - used);
        copy_in(self.bytes, write_pos % self.bytes.len, src[0..n]);
        self.write_count.store(write_pos +% n, .release);
        return n;
    }

    /// Copies as much queued data as fits in `dst` and returns the copied byte
    /// count. Call only from the one consumer thread.
    pub fn read(self: *ByteFifo, dst: []u8) usize {
        const read_pos = self.read_count.load(.monotonic);
        const write_pos = self.write_count.load(.acquire);
        const available = write_pos -% read_pos;
        std.debug.assert(available <= self.bytes.len);

        const n = @min(dst.len, available);
        copy_out(dst[0..n], self.bytes, read_pos % self.bytes.len);
        self.read_count.store(read_pos +% n, .release);
        return n;
    }
};

fn copy_in(dst: []u8, start: usize, src: []const u8) void {
    if (src.len == 0) return;
    const first_len = @min(src.len, dst.len - start);
    @memcpy(dst[start..][0..first_len], src[0..first_len]);
    if (first_len < src.len) @memcpy(dst[0 .. src.len - first_len], src[first_len..]);
}

fn copy_out(dst: []u8, src: []const u8, start: usize) void {
    if (dst.len == 0) return;
    const first_len = @min(dst.len, src.len - start);
    @memcpy(dst[0..first_len], src[start..][0..first_len]);
    if (first_len < dst.len) @memcpy(dst[first_len..], src[0 .. dst.len - first_len]);
}

test "byte fifo preserves order across wraparound" {
    var storage: [8]u8 = undefined;
    var fifo = ByteFifo.init(&storage);

    try std.testing.expectEqual(@as(usize, 6), fifo.write("abcdef"));
    var first: [5]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 5), fifo.read(&first));
    try std.testing.expectEqualStrings("abcde", &first);

    try std.testing.expectEqual(@as(usize, 6), fifo.write("ghijkl"));
    var second: [7]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 7), fifo.read(&second));
    try std.testing.expectEqualStrings("fghijkl", &second);
    try std.testing.expectEqual(@as(usize, 0), fifo.readable());
}

test "byte fifo reports bounded readable and writable space" {
    var storage: [4]u8 = undefined;
    var fifo = ByteFifo.init(&storage);

    try std.testing.expectEqual(@as(usize, 4), fifo.writable());
    try std.testing.expectEqual(@as(usize, 4), fifo.write("12345"));
    try std.testing.expectEqual(@as(usize, 0), fifo.writable());

    var out: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), fifo.read(&out));
    try std.testing.expectEqualStrings("12", &out);
    try std.testing.expectEqual(@as(usize, 2), fifo.readable());
    try std.testing.expectEqual(@as(usize, 2), fifo.writable());
}

test "byte fifo reset clears queued data" {
    var storage: [4]u8 = undefined;
    var fifo = ByteFifo.init(&storage);

    _ = fifo.write("abc");
    fifo.reset();

    try std.testing.expectEqual(@as(usize, 0), fifo.readable());
    try std.testing.expectEqual(@as(usize, 4), fifo.writable());
}

test "byte fifo consumer can discard while preserving later writes" {
    var storage: [8]u8 = undefined;
    var fifo = ByteFifo.init(&storage);

    _ = fifo.write("abcd");
    fifo.discard_all();
    try std.testing.expectEqual(@as(usize, 0), fifo.readable());

    try std.testing.expectEqual(@as(usize, 4), fifo.write("efgh"));
    var out: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), fifo.read(&out));
    try std.testing.expectEqualStrings("efgh", &out);
}
