//! Focus loss suspends text input without discarding the session's buffer.

const options = @import("options");
const Math = @import("platform").math;

/// Upper bound on session text; `TextInputOptions.max_bytes` may lower it.
pub const max_text_input_bytes: usize = switch (options.config.platform) {
    .psp, .nintendo_3ds, .nintendo_switch => 512,
    .windows, .linux, .macos, .wasm => 4096,
};

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
    buffer: [max_text_input_bytes]u8 = undefined,
    len: usize = 0,
    status: TextInputStatus = .active,

    pub fn text(self: *const TextInputSession) []const u8 {
        return self.buffer[0..self.len];
    }

    pub fn limit(self: *const TextInputSession) usize {
        return Math.min(self.options.max_bytes orelse self.buffer.len, self.buffer.len);
    }

    /// Bytes past `limit` are discarded.
    pub fn append(self: *TextInputSession, bytes: []const u8) void {
        const take = Math.min(self.limit() -| self.len, bytes.len);
        @memcpy(self.buffer[self.len..][0..take], bytes[0..take]);
        self.len += take;
    }

    pub fn clear(self: *TextInputSession) void {
        self.len = 0;
    }

    pub fn delete_last_codepoint(self: *TextInputSession) void {
        if (self.len == 0) return;
        var at = self.len - 1;
        while (at > 0 and (self.buffer[at] & 0xc0) == 0x80) : (at -= 1) {}
        self.len = at;
    }

    pub fn is_terminal(self: *const TextInputSession) bool {
        return self.status == .submitted or self.status == .cancelled;
    }
};
