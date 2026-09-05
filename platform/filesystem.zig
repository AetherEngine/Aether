//! Filesystem behavior used by Core's replacement-write helper.
pub const rename_replaces_destination = @import("options").config.platform != .psp;

/// Includes space for a native terminator. The PSP SDK and Switch I/O adapter
/// use 1024-byte path buffers; Zig's standard limit omits those OS targets.
pub const max_path_bytes = switch (@import("options").config.platform) {
    .psp, .nintendo_switch => 1024,
    else => @import("std").Io.Dir.max_path_bytes,
};
