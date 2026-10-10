const system = @import("../system.zig");

pub fn info() system.Info {
    return .{
        .hardware = .nintendo_switch,
        .input = .{ .pointer = true, .native_text_entry = true, .built_in_sticks = 2 },
        .native_thread_priority = true,
    };
}
