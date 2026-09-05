//! Focus loss suspends text input without discarding the session's buffer.

const std = @import("std");

pub const TextInputStatus = enum(u8) {
    active,
    suspended,
    submitted,
    cancelled,
};

pub const TextInputTarget = struct {
    /// Borrowed from the caller for the session's lifetime.
    id: []const u8,
};

pub const TextInputOptions = struct {
    multiline: bool = false,
    max_bytes: ?usize = null,
    initial: ?[]const u8 = null,
};

pub const TextInputSession = struct {
    target: TextInputTarget,
    options: TextInputOptions,
    buffer: std.ArrayList(u8) = .empty,
    status: TextInputStatus = .active,

    pub fn append(self: *TextInputSession, alloc: std.mem.Allocator, text: []const u8) !void {
        const remaining = if (self.options.max_bytes) |limit| limit -| self.buffer.items.len else text.len;
        try self.buffer.appendSlice(alloc, text[0..@min(remaining, text.len)]);
    }

    pub fn deinit(self: *TextInputSession, alloc: std.mem.Allocator) void {
        defer self.* = undefined;

        self.buffer.deinit(alloc);
    }

    pub fn is_terminal(self: *const TextInputSession) bool {
        return self.status == .submitted or self.status == .cancelled;
    }
};
