const std = @import("std");
const options = @import("options");
const psp_system = @import("psp/system.zig");
const system_3ds = @import("3ds/system.zig");
pub const api = @import("system_api.zig");
pub const Info = api.Info;
pub const Hardware = api.Hardware;

/// Available services and built-in hardware, not application quality settings.
pub fn info() Info {
    var result: Info = switch (options.config.platform) {
        .psp => psp_system.info(),
        .nintendo_3ds => system_3ds.info(),
        .nintendo_switch => .{ .hardware = .nintendo_switch, .input = .{ .pointer = true, .native_text_entry = true, .built_in_sticks = 2 }, .native_thread_priority = true },
        .wasm => .{ .hardware = .browser, .input = .{ .pointer = true, .keyboard = true }, .background_workers = false, .stream_networking = false, .browser_file_export = true },
        else => .{ .hardware = .desktop, .input = .{ .pointer = true, .keyboard = true } },
    };
    if (options.config.gfx == .headless) result.input = .{};
    return result;
}

test "headless capability queries describe implemented input" {
    if (options.config.gfx == .headless) {
        try std.testing.expect(!info().input.pointer);
        try std.testing.expect(!info().input.native_text_entry);
    }
}
