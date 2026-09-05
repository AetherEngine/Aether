pub const InitError = error{
    OutOfMemory,
    SurfaceInitFailed,
    VulkanNotSupported,
};

/// Surfaces own window state; graphics backends use module-level state.
pub fn InterfaceType(comptime Backend: type) type {
    return struct {
        init: fn (*Backend, u32, u32, [:0]const u8, bool, bool, bool) InitError!void,
        deinit: fn (*Backend) void,
        update: fn (*Backend) bool,
        draw: fn (*Backend) void,
        get_width: fn (*Backend) u32,
        get_height: fn (*Backend) u32,
    };
}

pub fn assert_impl(comptime Backend: type) void {
    @import("contract.zig").assert_impl("surface", Backend, InterfaceType(Backend));
}
