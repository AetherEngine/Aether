//! Allocation-free frame selection and copying for a regular image grid.
//! Time is supplied by the application. CPU copies require an explicit texture
//! update afterwards, which uploads the complete texture on current backends.
const std = @import("std");
const Image = @import("../util/image.zig");
const Texture = @import("texture.zig");
const Flipbook = @This();

pub const Playback = enum { loop, once, ping_pong };
pub const Error = error{ InvalidFlipbook, InvalidTime, FrameOutOfBounds };
pub const Desc = struct {
    frame_width: u32,
    frame_height: u32,
    frame_count: u32,
    frames_per_second: f32,
    playback: Playback = .loop,
};

source_width: u32,
source_height: u32,
columns: u32,
desc: Desc,

/// Frames occupy a tightly tiled grid in row-major order. The image dimensions
/// must be exact multiples of the frame size; unused final tiles are allowed.
pub fn init(source: Image.View, desc: Desc) (Error || Image.RegionError)!Flipbook {
    try source.validate();
    if (desc.frame_width == 0 or desc.frame_height == 0 or desc.frame_count == 0 or
        !std.math.isFinite(desc.frames_per_second) or desc.frames_per_second <= 0 or
        source.width % desc.frame_width != 0 or source.height % desc.frame_height != 0)
        return error.InvalidFlipbook;
    const columns = source.width / desc.frame_width;
    const rows = source.height / desc.frame_height;
    if (@as(u64, columns) * rows < desc.frame_count) return error.InvalidFlipbook;
    return .{ .source_width = source.width, .source_height = source.height, .columns = columns, .desc = desc };
}

pub fn frame_at(self: Flipbook, elapsed_seconds: f64) Error!u32 {
    if (!std.math.isFinite(elapsed_seconds) or elapsed_seconds < 0) return error.InvalidTime;
    const step = @floor(elapsed_seconds * self.desc.frames_per_second);
    if (!std.math.isFinite(step)) return error.InvalidTime;
    const count: f64 = @floatFromInt(self.desc.frame_count);
    return switch (self.desc.playback) {
        .once => @intFromFloat(@min(step, count - 1)),
        .loop => @intFromFloat(@mod(step, count)),
        .ping_pong => if (self.desc.frame_count == 1) 0 else blk: {
            const period = 2 * (count - 1);
            const phase = @mod(step, period);
            break :blk @intFromFloat(if (phase < count) phase else period - phase);
        },
    };
}

pub fn frame_region(self: Flipbook, frame: u32) Error!Image.Region {
    if (frame >= self.desc.frame_count) return error.FrameOutOfBounds;
    return .{
        .x = frame % self.columns * self.desc.frame_width,
        .y = frame / self.columns * self.desc.frame_height,
        .width = self.desc.frame_width,
        .height = self.desc.frame_height,
    };
}

pub fn copy_to_image(self: Flipbook, destination: Image.MutableView, source: Image.View, frame: u32, x: u32, y: u32) (Error || Image.RegionError)!void {
    try self.validate_source(source);
    try destination.copy_region(source, try self.frame_region(frame), x, y);
}

pub fn copy_to_texture(self: Flipbook, destination: *Texture, source: Image.View, frame: u32, x: u32, y: u32) (Error || Texture.RegionError)!void {
    try self.validate_source(source);
    try destination.copy_image_region(source, try self.frame_region(frame), x, y);
}

fn validate_source(self: Flipbook, source: Image.View) Error!void {
    if (source.width != self.source_width or source.height != self.source_height) return error.InvalidFlipbook;
}

test "flipbook grid bounds playback and copying" {
    const source: Image.View = .{ .width = 2, .height = 2, .data = &.{ 1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255, 4, 0, 0, 255 } };
    var flipbook = try init(source, .{ .frame_width = 1, .frame_height = 1, .frame_count = 4, .frames_per_second = 2 });
    try std.testing.expectEqual(@as(u32, 0), try flipbook.frame_at(2));
    try std.testing.expectEqual(@as(u32, 3), try flipbook.frame_at(1.75));
    flipbook.desc.playback = .once;
    try std.testing.expectEqual(@as(u32, 3), try flipbook.frame_at(20));
    flipbook.desc.playback = .ping_pong;
    const expected = [_]u32{ 0, 1, 2, 3, 2, 1, 0, 1 };
    for (expected, 0..) |frame, i| try std.testing.expectEqual(frame, try flipbook.frame_at(@as(f64, @floatFromInt(i)) / 2));
    var output: [4]u8 = undefined;
    try flipbook.copy_to_image(.{ .width = 1, .height = 1, .data = &output }, source, 2, 0, 0);
    try std.testing.expectEqual([4]u8{ 3, 0, 0, 255 }, output);
    try std.testing.expectError(error.InvalidTime, flipbook.frame_at(-1));
    try std.testing.expectError(error.FrameOutOfBounds, flipbook.frame_region(4));
    try std.testing.expectError(error.InvalidFlipbook, init(source, .{ .frame_width = 1, .frame_height = 1, .frame_count = 5, .frames_per_second = 1 }));
}
