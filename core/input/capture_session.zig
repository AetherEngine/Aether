//! Rebinding waits for a fresh down-edge. Sources held at the start must
//! first be released; key repeats never complete capture.

const std = @import("std");
const data = @import("platform").input_api.data;
const binding_mod = @import("binding.zig");

pub const CaptureNextInputStatus = enum(u8) {
    waiting,
    captured,
    cancelled,
};

pub const CaptureResult = struct {
    source: binding_mod.BindingSource,
    modifiers: data.ModifierSet,
    display_buf: [64]u8 = @splat(0),
    display_len: u8 = 0,

    pub fn display_label(self: *const CaptureResult) []const u8 {
        return self.display_buf[0..self.display_len];
    }
};

pub const CaptureNextInputSession = struct {
    eligible_kinds: std.EnumSet(binding_mod.BindingSourceKind),
    held_at_start: std.ArrayList(binding_mod.BindingSource) = .empty,
    status: CaptureNextInputStatus = .waiting,
    result: CaptureResult = undefined,

    pub fn deinit(self: *CaptureNextInputSession, alloc: std.mem.Allocator) void {
        defer self.* = undefined;

        self.held_at_start.deinit(alloc);
    }

    pub fn is_terminal(self: *const CaptureNextInputSession) bool {
        return self.status == .captured or self.status == .cancelled;
    }
};

pub fn source_eq(a: binding_mod.BindingSource, b: binding_mod.BindingSource) bool {
    return std.meta.eql(a, b);
}

pub fn arm_on_release(session: *CaptureNextInputSession, src: binding_mod.BindingSource) void {
    for (session.held_at_start.items, 0..) |held, i| {
        if (source_eq(held, src)) {
            _ = session.held_at_start.swapRemove(i);
            return;
        }
    }
}

pub fn eligible_to_complete(session: *const CaptureNextInputSession, src: binding_mod.BindingSource) bool {
    for (session.held_at_start.items) |held| {
        if (source_eq(held, src)) return false;
    }
    return true;
}

pub fn format_label(buf: *[64]u8, src: binding_mod.BindingSource, mods: data.ModifierSet) u8 {
    const label = @import("display.zig").format_label(buf, src, mods, .readable) catch return 0;
    return @intCast(label.len);
}
