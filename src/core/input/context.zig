//! Context stack: layered InputContexts whose top owns cursor mode and the
//! action set the game polls. Lower layers are masked completely; pushing
//! a layer hides everything below it.

const std = @import("std");
const action = @import("action.zig");

pub const CursorMode = enum(u8) {
    captured,
    free,
    hidden,
    visible,
};

pub const InputContext = struct {
    name: []const u8,
    cursor_mode: CursorMode,
    actions: action.ActionSetHandle,
    consumes_text: bool = false,
    consumes_pointer: bool = true,
};

pub const max_layers: usize = 16;

/// Fixed-cap stack -- push/pop are O(1) and require no heap. The base
/// layer (index 0) is created at init and may not be popped.
pub const ContextStack = struct {
    layers: [max_layers]InputContext = undefined,
    len: u8 = 0,

    pub fn push(self: *ContextStack, ctx: InputContext) !void {
        if (self.len >= max_layers) return error.ContextStackFull;
        self.layers[self.len] = ctx;
        self.len += 1;
    }

    pub fn pop(self: *ContextStack) !InputContext {
        if (self.len <= 1) return error.ContextStackBaseProtected;
        self.len -= 1;
        return self.layers[self.len];
    }

    pub fn replace_top(self: *ContextStack, ctx: InputContext) !InputContext {
        if (self.len == 0) return error.ContextStackEmpty;
        const old = self.layers[self.len - 1];
        self.layers[self.len - 1] = ctx;
        return old;
    }

    pub fn top(self: *const ContextStack) ?*const InputContext {
        return if (self.len == 0) null else &self.layers[self.len - 1];
    }

    pub fn slice(self: *const ContextStack) []const InputContext {
        return self.layers[0..self.len];
    }

    pub fn references(self: *const ContextStack, set: action.ActionSetHandle) bool {
        for (self.slice()) |layer| {
            if (layer.actions == set) return true;
        }
        return false;
    }
};

/// Effective cursor mode for the current top of stack. Returns `.visible`
/// when the stack is empty so platform code never sees a degenerate state.
pub fn effective_cursor_mode(stack: *const ContextStack) CursorMode {
    if (stack.top()) |t| return t.cursor_mode;
    return .visible;
}
