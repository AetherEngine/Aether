//! Comptime-selected thread backend.

const builtin = @import("builtin");
const thread_api = @import("thread_api.zig");

pub const Api = if (builtin.os.tag == .psp)
    @import("psp/psp_thread.zig")
else
    @import("std_thread.zig");

comptime {
    thread_api.assert_impl(Api);
}
