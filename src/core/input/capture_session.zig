//! Capture-next-input session for rebinding flows.
//!
//! Single-slot -- spec invariant SingleWaitingCaptureSession permits at
//! most one waiting session at a time.
//!
//! Sources held when the session begins go into `held_at_start`. Each
//! must transition through their released equivalent before becoming
//! eligible to complete capture: that release moves the source into
//! `armed`. A fresh down-edge from an armed source -- or any source not
//! held at start -- completes capture. Key-repeat events never complete.

const std = @import("std");
const data = @import("data.zig");
const binding_mod = @import("binding.zig");

pub const CaptureNextInputStatus = enum(u8) {
    waiting,
    captured,
    cancelled,
};

pub const CaptureResult = struct {
    source: binding_mod.BindingSource,
    modifiers: data.ModifierSet,
    /// Inline label storage -- formatted at the point of completion so the
    /// game can render it without owning any allocator.
    display_buf: [64]u8 = @splat(0),
    display_len: u8 = 0,

    pub fn display_label(self: *const CaptureResult) []const u8 {
        return self.display_buf[0..self.display_len];
    }
};

pub const CaptureNextInputSession = struct {
    eligible_kinds: std.EnumSet(binding_mod.BindingSourceKind),
    held_at_start: std.ArrayList(binding_mod.BindingSource) = .empty,
    armed: std.ArrayList(binding_mod.BindingSource) = .empty,
    status: CaptureNextInputStatus = .waiting,
    result: CaptureResult = undefined,

    pub fn deinit(self: *CaptureNextInputSession, alloc: std.mem.Allocator) void {
        self.held_at_start.deinit(alloc);
        self.armed.deinit(alloc);
    }

    pub fn is_terminal(self: *const CaptureNextInputSession) bool {
        return self.status == .captured or self.status == .cancelled;
    }
};

/// True when `s` matches `target` by value. BindingSource is a tagged
/// union with non-comparable fields (sets) so `std.meta.eql` is unsafe.
pub fn source_eq(a: binding_mod.BindingSource, b: binding_mod.BindingSource) bool {
    if (@as(binding_mod.BindingSourceKind, a) != @as(binding_mod.BindingSourceKind, b)) return false;
    return switch (a) {
        .key => |k| k == b.key,
        .mouse_button => |mb| mb == b.mouse_button,
        .mouse_wheel => |ax| ax == b.mouse_wheel,
        .mouse_delta => |ax| ax == b.mouse_delta,
        .gamepad_button => |gb| gb == b.gamepad_button,
        .gamepad_axis => |ga| ga == b.gamepad_axis,
    };
}

fn list_remove(list: *std.ArrayList(binding_mod.BindingSource), src: binding_mod.BindingSource) bool {
    var i: usize = 0;
    while (i < list.items.len) : (i += 1) {
        if (source_eq(list.items[i], src)) {
            _ = list.swapRemove(i);
            return true;
        }
    }
    return false;
}

fn list_contains(list: *const std.ArrayList(binding_mod.BindingSource), src: binding_mod.BindingSource) bool {
    for (list.items) |entry| {
        if (source_eq(entry, src)) return true;
    }
    return false;
}

/// Move a released source from `held_at_start` to `armed`, if present.
/// Idempotent: a source already armed stays armed; a source neither held
/// nor armed is ignored.
pub fn arm_on_release(session: *CaptureNextInputSession, alloc: std.mem.Allocator, src: binding_mod.BindingSource) !void {
    if (list_remove(&session.held_at_start, src)) {
        try session.armed.append(alloc, src);
    }
}

/// True when a fresh down-edge for `src` should complete capture: source
/// is armed, or was never held when the session began.
pub fn eligible_to_complete(session: *const CaptureNextInputSession, src: binding_mod.BindingSource) bool {
    if (list_contains(&session.armed, src)) return true;
    if (list_contains(&session.held_at_start, src)) return false;
    return true;
}

pub fn format_label(buf: *[64]u8, src: binding_mod.BindingSource, mods: data.ModifierSet) u8 {
    var stream = std.Io.Writer.fixed(buf);
    if (mods.contains(.ctrl)) stream.writeAll("Ctrl+") catch {};
    if (mods.contains(.shift)) stream.writeAll("Shift+") catch {};
    if (mods.contains(.alt)) stream.writeAll("Alt+") catch {};
    if (mods.contains(.super)) stream.writeAll("Super+") catch {};
    switch (src) {
        .key => |k| stream.print("{s}", .{@tagName(k)}) catch {},
        .mouse_button => |mb| stream.print("Mouse {s}", .{@tagName(mb)}) catch {},
        .mouse_wheel => |ax| stream.print("Wheel {s}", .{@tagName(ax)}) catch {},
        .mouse_delta => |ax| stream.print("Mouse Delta {s}", .{@tagName(ax)}) catch {},
        .gamepad_button => |gb| stream.print("Pad {s}", .{@tagName(gb)}) catch {},
        .gamepad_axis => |ga| stream.print("Pad Axis {s}", .{@tagName(ga)}) catch {},
    }
    return @intCast(stream.end);
}
