//! Lock-free single-producer/single-consumer byte FIFO used by the 3DS audio
//! streaming worker. The producer is the filesystem worker and the consumer
//! is the real-time mixer thread.

const std = @import("std");
const math = @import("math");
const assert = std.debug.assert;

pub const ByteFifo = struct {
    bytes: []u8,
    read_count: std.atomic.Value(usize) = .init(0),
    write_count: std.atomic.Value(usize) = .init(0),

    pub fn init(bytes: []u8) ByteFifo {
        assert(bytes.len > 0);
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
        assert(count <= self.bytes.len);
        return count;
    }

    /// Bytes currently available to the producer.
    pub fn writable(self: *const ByteFifo) usize {
        const read_pos = self.read_count.load(.acquire);
        const write_pos = self.write_count.load(.monotonic);
        const used = write_pos -% read_pos;
        assert(used <= self.bytes.len);
        return self.bytes.len - used;
    }

    /// Copies as much of `src` as fits and returns the copied byte count.
    /// Call only from the one producer thread.
    pub fn write(self: *ByteFifo, src: []const u8) usize {
        const write_pos = self.write_count.load(.monotonic);
        const read_pos = self.read_count.load(.acquire);
        const used = write_pos -% read_pos;
        assert(used <= self.bytes.len);

        const n = math.min(src.len, self.bytes.len - used);
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
        assert(available <= self.bytes.len);

        const n = math.min(dst.len, available);
        copy_out(dst[0..n], self.bytes, read_pos % self.bytes.len);
        self.read_count.store(read_pos +% n, .release);
        return n;
    }
};

fn copy_in(dst: []u8, start: usize, src: []const u8) void {
    if (src.len == 0) return;
    const first_len = math.min(src.len, dst.len - start);
    @memcpy(dst[start..][0..first_len], src[0..first_len]);
    if (first_len < src.len) @memcpy(dst[0 .. src.len - first_len], src[first_len..]);
}

fn copy_out(dst: []u8, src: []const u8, start: usize) void {
    if (dst.len == 0) return;
    const first_len = math.min(dst.len, src.len - start);
    @memcpy(dst[0..first_len], src[start..][0..first_len]);
    if (first_len < dst.len) @memcpy(dst[first_len..], src[0 .. dst.len - first_len]);
}
