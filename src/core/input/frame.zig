//! Per-frame raw event stream + pointer state.
//!
//! Backends call `deliver_*` (from input.zig) which appends a `RawEvent`
//! to the active accumulator. `signal_frame_boundary` swaps accumulator
//! and published buffers, so `frame()` returns events with stable lifetime
//! until the next boundary. Text payloads index into a parallel byte arena
//! that is swapped in lockstep, keeping the slice references valid.

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

/// Double-buffered event + string storage. The accumulator captures
/// `deliver_*` calls; on swap, the accumulator becomes the published
/// frame and the previous publication is cleared for reuse.
pub const FrameBuffer = struct {
    alloc: std.mem.Allocator,
    events_a: std.ArrayList(RawEvent) = .empty,
    events_b: std.ArrayList(RawEvent) = .empty,
    strings_a: std.ArrayList(u8) = .empty,
    strings_b: std.ArrayList(u8) = .empty,
    accum_is_a: bool = true,
    sequence: u64 = 0,
    frame_sequence: u64 = 0,

    pub fn init(alloc: std.mem.Allocator) FrameBuffer {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *FrameBuffer) void {
        self.events_a.deinit(self.alloc);
        self.events_b.deinit(self.alloc);
        self.strings_a.deinit(self.alloc);
        self.strings_b.deinit(self.alloc);
    }

    fn accum_events(self: *FrameBuffer) *std.ArrayList(RawEvent) {
        return if (self.accum_is_a) &self.events_a else &self.events_b;
    }

    fn accum_strings(self: *FrameBuffer) *std.ArrayList(u8) {
        return if (self.accum_is_a) &self.strings_a else &self.strings_b;
    }

    fn pub_events(self: *FrameBuffer) *std.ArrayList(RawEvent) {
        return if (self.accum_is_a) &self.events_b else &self.events_a;
    }

    fn pub_strings(self: *FrameBuffer) *std.ArrayList(u8) {
        return if (self.accum_is_a) &self.strings_b else &self.strings_a;
    }

    /// Allocate a sequence number and append an event whose `kind` does
    /// not need to reference the string arena.
    pub fn append_event(self: *FrameBuffer, kind: RawEvent.Kind) !u64 {
        self.sequence += 1;
        try self.accum_events().append(self.alloc, .{ .sequence = self.sequence, .kind = kind });
        return self.sequence;
    }

    /// Copy `text` into the accumulator's string arena and return a slice
    /// that stays valid until the buffer is published and re-used (one
    /// full frame later).
    pub fn intern_text(self: *FrameBuffer, text: []const u8) ![]const u8 {
        const strings = self.accum_strings();
        const start = strings.items.len;
        try strings.appendSlice(self.alloc, text);
        return strings.items[start..];
    }

    /// Flip accumulator and published buffers. The newly-accumulating
    /// buffer (previously published) is reset for reuse.
    pub fn signal_frame_boundary(self: *FrameBuffer) void {
        self.accum_is_a = !self.accum_is_a;
        self.frame_sequence += 1;
        // Reset the buffer that will accumulate the next frame.
        self.accum_events().clearRetainingCapacity();
        self.accum_strings().clearRetainingCapacity();
    }

    pub fn published_events(self: *FrameBuffer) []const RawEvent {
        return self.pub_events().items;
    }
};
