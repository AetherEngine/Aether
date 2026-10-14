//! Published events and text remain valid until the next frame boundary.

const options = @import("options");
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
    dropped_events: u32 = 0,
};

pub const limits = struct {
    pub const max_events_per_frame: usize = switch (options.config.platform) {
        .psp, .nintendo_3ds, .nintendo_switch => 128,
        .windows, .linux, .macos, .wasm => 512,
    };
    pub const max_text_bytes_per_frame: usize = switch (options.config.platform) {
        .psp, .nintendo_3ds, .nintendo_switch => 512,
        .windows, .linux, .macos, .wasm => 4096,
    };
};

const FrameSide = struct {
    events: [limits.max_events_per_frame]RawEvent = undefined,
    event_count: usize = 0,
    text: [limits.max_text_bytes_per_frame]u8 = undefined,
    text_len: usize = 0,
    dropped: u32 = 0,

    fn clear(self: *FrameSide) void {
        self.event_count = 0;
        self.text_len = 0;
        self.dropped = 0;
    }
};

pub const FrameBuffer = struct {
    sides: [2]FrameSide = @splat(.{}),
    accum: u1 = 0,
    sequence: u64 = 0,
    frame_sequence: u64 = 0,

    pub fn record_event(self: *FrameBuffer, kind: RawEvent.Kind) void {
        const side = &self.sides[self.accum];
        if (side.event_count == side.events.len) {
            side.dropped +|= 1;
            return;
        }
        self.sequence += 1;
        side.events[side.event_count] = .{ .sequence = self.sequence, .kind = kind };
        side.event_count += 1;
    }

    /// Text is copied and remains valid through publication of its frame.
    pub fn record_text(self: *FrameBuffer, text: []const u8) void {
        const side = &self.sides[self.accum];
        if (side.event_count == side.events.len or text.len > side.text.len - side.text_len) {
            side.dropped +|= 1;
            return;
        }
        const stored = side.text[side.text_len..][0..text.len];
        @memcpy(stored, text);
        side.text_len += text.len;
        self.record_event(.{ .text_utf8 = .{ .text = stored } });
    }

    pub fn signal_frame_boundary(self: *FrameBuffer) void {
        self.accum ^= 1;
        self.sides[self.accum].clear();
        self.frame_sequence += 1;
    }

    pub fn published_events(self: *const FrameBuffer) []const RawEvent {
        const side = &self.sides[self.accum ^ 1];
        return side.events[0..side.event_count];
    }

    pub fn published_dropped(self: *const FrameBuffer) u32 {
        return self.sides[self.accum ^ 1].dropped;
    }
};
