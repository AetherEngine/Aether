//! Comptime-selected thread backend.

const builtin = @import("builtin");
const options = @import("options");
const thread_api = @import("thread_api.zig");

pub const Api = if (builtin.os.tag == .psp)
    @import("psp/psp_thread.zig")
else if (builtin.os.tag == .@"3ds")
    @import("3ds/3ds_thread.zig")
else if (options.config.platform == .nintendo_switch)
    @import("switch/switch_thread.zig")
else if (options.config.platform == .wasm)
    @import("wasm/wasm_thread.zig")
else
    @import("std_thread.zig");

comptime {
    thread_api.assert_impl(Api);
}
