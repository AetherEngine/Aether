const sdk = @import("pspsdk");
const system = @import("../system.zig");

pub fn info() system.Info {
    return .{
        .hardware = switch (sdk.model.current()) {
            .phat => .psp_phat,
            .slim => .psp_slim,
        },
        .input = .{ .native_text_entry = true, .built_in_sticks = 1 },
        .worker_inherits_cwd = false,
        .native_thread_priority = true,
    };
}
