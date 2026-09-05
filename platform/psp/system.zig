const sdk = @import("pspsdk");
const api = @import("../system_api.zig");

pub fn info() api.Info {
    return .{
        .hardware = switch (sdk.model.current()) {
            .phat => .psp_phat,
            .slim => .psp_slim,
        },
        .input = .{ .native_text_entry = true, .built_in_sticks = 1 },
        .worker_inherits_cwd = false,
        .native_thread_priority = true,
        .rename_replaces_destination = false,
    };
}
