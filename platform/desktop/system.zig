const system = @import("../system.zig");

pub fn info() system.Info {
    return .{ .hardware = .desktop, .input = .{ .pointer = true, .keyboard = true } };
}
