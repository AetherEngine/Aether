const std = @import("std");

pub const cache_line_bytes: usize = 64;

pub const Range = struct {
    ptr: *const anyopaque,
    len: u32,
};

/// Return the complete cache-line range covering `ptr[0..len]`.
///
/// PSP cache operations work on 64-byte lines. Their range arguments must
/// cover complete lines, even when the producer's allocation is only
/// naturally aligned for its element type.
pub fn covering_range(ptr: *const anyopaque, len: usize) Range {
    std.debug.assert(len > 0);

    const start = std.mem.alignBackward(usize, @intFromPtr(ptr), cache_line_bytes);
    const end = std.mem.alignForward(usize, @intFromPtr(ptr) + len, cache_line_bytes);
    const span = end - start;
    std.debug.assert(span <= std.math.maxInt(u32));

    return .{
        .ptr = @ptrFromInt(start),
        .len = @intCast(span),
    };
}

test "covering_range preserves an aligned cache line" {
    const range = covering_range(@ptrFromInt(0x0880_1000), 64);
    try std.testing.expectEqual(@as(usize, 0x0880_1000), @intFromPtr(range.ptr));
    try std.testing.expectEqual(@as(u32, 64), range.len);
}

test "covering_range expands a short unaligned vertex range" {
    const range = covering_range(@ptrFromInt(0x0880_1010), 16);
    try std.testing.expectEqual(@as(usize, 0x0880_1000), @intFromPtr(range.ptr));
    try std.testing.expectEqual(@as(u32, 64), range.len);
}

test "covering_range expands an index range across cache lines" {
    const range = covering_range(@ptrFromInt(0x0880_103c), 12);
    try std.testing.expectEqual(@as(usize, 0x0880_1000), @intFromPtr(range.ptr));
    try std.testing.expectEqual(@as(u32, 128), range.len);
}
