//! Texture resources and native uploads exchanged with graphics backends.
const HandleType = @import("../util/handle.zig").HandleType;

pub const TextureHandleTag = enum {};
pub const Handle = HandleType(TextureHandleTag);

pub const Residency = enum {
    backend_default,
    system_ram,
    prefer_vram,
};

/// Pixels use the selected backend's native format and layout. Core owns the
/// storage and keeps it alive until the texture is destroyed.
pub const UploadDesc = struct {
    width: u32,
    height: u32,
    pixels: []align(16) u8,
    residency: Residency = .backend_default,
};
