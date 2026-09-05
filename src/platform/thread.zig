const options = @import("options");
const thread_api = @import("thread_api.zig");

pub const Api = switch (options.config.platform) {
    .psp => @import("psp/psp_thread.zig"),
    .nintendo_3ds => @import("3ds/thread.zig"),
    .nintendo_switch => @import("switch/switch_thread.zig"),
    .wasm => @import("wasm/wasm_thread.zig"),
    else => @import("std_thread.zig"),
};

comptime {
    thread_api.assert_impl(Api);
}
