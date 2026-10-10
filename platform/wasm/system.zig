const system = @import("../system.zig");

pub fn info() system.Info {
    return .{
        .hardware = .browser,
        .input = .{ .pointer = true, .keyboard = true },
        .background_workers = false,
        .stream_networking = false,
    };
}
