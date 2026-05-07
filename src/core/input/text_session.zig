//! Text-input session state machine. Single-slot -- at most one
//! non-terminal session is allowed (spec invariant
//! SingleNonTerminalTextSession). Buffer accumulates from TextUtf8 events
//! while active; suspended sessions drop incoming text but preserve their
//! buffer; focus loss/gain flips active <-> suspended without cancelling.

const std = @import("std");

pub const TextInputStatus = enum(u8) {
    active,
    suspended,
    submitted,
    cancelled,
};

pub const TextInputTarget = struct {
    /// Borrowed identifier -- caller-owned. Useful for routing the
    /// completed buffer back to the UI element that requested it.
    id: []const u8,
};

pub const TextInputOptions = struct {
    multiline: bool = false,
    max_bytes: ?usize = null,
};

pub const TextInputSession = struct {
    target: TextInputTarget,
    options: TextInputOptions,
    buffer: std.ArrayList(u8) = .empty,
    status: TextInputStatus = .active,

    pub fn append(self: *TextInputSession, alloc: std.mem.Allocator, text: []const u8) !void {
        if (self.options.max_bytes) |limit| {
            const remaining = if (self.buffer.items.len < limit) limit - self.buffer.items.len else 0;
            const take = @min(remaining, text.len);
            if (take == 0) return;
            try self.buffer.appendSlice(alloc, text[0..take]);
        } else {
            try self.buffer.appendSlice(alloc, text);
        }
    }

    pub fn deinit(self: *TextInputSession, alloc: std.mem.Allocator) void {
        self.buffer.deinit(alloc);
    }

    pub fn is_terminal(self: *const TextInputSession) bool {
        return self.status == .submitted or self.status == .cancelled;
    }
};
