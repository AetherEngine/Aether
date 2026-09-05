const api = @import("../system_api.zig");
const app = @import("app.zig");

pub fn info() api.Info {
    const new = app.is_new();
    return .{ .hardware = if (new) .new_3ds else .old_3ds, .input = .{
        .pointer = true,
        .native_text_entry = true,
        .built_in_sticks = if (new) 2 else 1,
    }, .native_thread_priority = true };
}
