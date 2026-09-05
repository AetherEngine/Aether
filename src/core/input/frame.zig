//! Published events and text remain valid until the next frame boundary.

const std = @import("std");
const data = @import("data.zig");

pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
};

pub const Pointer = struct {
    position: Vec2 = .{},
    delta: Vec2 = .{},
};

pub const RawEvent = struct {
    sequence: u64,
    kind: Kind,

    pub const Kind = union(enum) {
        key_down: struct { key: data.Key, modifiers: data.ModifierSet, is_repeat: bool },
        key_up: struct { key: data.Key, modifiers: data.ModifierSet },
        text_utf8: struct { text: []const u8 },
        mouse_button_down: struct { button: data.MouseButton, position: Vec2 },
        mouse_button_up: struct { button: data.MouseButton, position: Vec2 },
        mouse_move_abs: struct { position: Vec2 },
        mouse_move_rel: struct { delta: Vec2 },
        mouse_wheel: struct { delta: Vec2 },
        gamepad_button_down: struct { button: data.Button },
        gamepad_button_up: struct { button: data.Button },
        gamepad_axis_changed: struct { axis: data.Axis, value: f32 },
        focus_lost,
        focus_gained,
    };
};

pub const InputFrame = struct {
    sequence: u64 = 0,
    events: []const RawEvent = &.{},
    pointer: Pointer = .{},
};

pub const FrameBuffer = struct {
    alloc: std.mem.Allocator,
    accum_events: std.ArrayList(RawEvent) = .empty,
    published: std.ArrayList(RawEvent) = .empty,
    accum_strings: std.heap.ArenaAllocator,
    published_strings: std.heap.ArenaAllocator,
    sequence: u64 = 0,
    frame_sequence: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) FrameBuffer {
        return .{
            .alloc = alloc,
            .accum_strings = .init(alloc),
            .published_strings = .init(alloc),
        };
    }

    pub fn deinit(self: *FrameBuffer) void {
        defer self.* = undefined;

        self.accum_events.deinit(self.alloc);
        self.published.deinit(self.alloc);
        self.accum_strings.deinit();
        self.published_strings.deinit();
    }

    pub fn append_event(self: *FrameBuffer, kind: RawEvent.Kind) !u64 {
        self.sequence += 1;
        try self.accum_events.append(self.alloc, .{ .sequence = self.sequence, .kind = kind });
        return self.sequence;
    }

    /// Text survives further appends and remains valid through publication.
    pub fn intern_text(self: *FrameBuffer, text: []const u8) ![]const u8 {
        return self.accum_strings.allocator().dupe(u8, text);
    }

    pub fn signal_frame_boundary(self: *FrameBuffer) void {
        std.mem.swap(std.ArrayList(RawEvent), &self.accum_events, &self.published);
        std.mem.swap(std.heap.ArenaAllocator, &self.accum_strings, &self.published_strings);
        self.frame_sequence += 1;
        self.accum_events.clearRetainingCapacity();
        _ = self.accum_strings.reset(.retain_capacity);
    }

    pub fn published_events(self: *FrameBuffer) []const RawEvent {
        return self.published.items;
    }
};

test "frame text survives arena growth and the next accumulator" {
    var fb = FrameBuffer.init(std.testing.allocator);
    defer fb.deinit();

    const first = try fb.intern_text("first");
    _ = try fb.append_event(.{ .text_utf8 = .{ .text = first } });
    const large = try std.testing.allocator.alloc(u8, 64 * 1024);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    const second = try fb.intern_text(large);
    _ = try fb.append_event(.{ .text_utf8 = .{ .text = second } });

    fb.signal_frame_boundary();
    const published = fb.published_events();
    try std.testing.expectEqualStrings("first", published[0].kind.text_utf8.text);
    try std.testing.expectEqualStrings(large, published[1].kind.text_utf8.text);
    const next = try fb.intern_text("next");
    _ = try fb.append_event(.{ .text_utf8 = .{ .text = next } });
    try std.testing.expectEqualStrings("first", published[0].kind.text_utf8.text);

    fb.signal_frame_boundary();
    try std.testing.expectEqual(@as(usize, 1), fb.published_events().len);
    try std.testing.expectEqualStrings("next", fb.published_events()[0].kind.text_utf8.text);
}
