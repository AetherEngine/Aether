//! Mesh resources exchanged between Core and graphics backends.
const HandleType = @import("../util/handle.zig").HandleType;

pub const MeshHandleTag = enum {};
pub const Handle = HandleType(MeshHandleTag);
pub const Index = u16;
pub const indexing_enabled = @import("options").config.mesh_indexing;

/// Borrowed sources must remain alive and unchanged until the backend is done
/// consuming them. Uploaded copies no longer depend on the source after update.
pub const SourceMode = enum { borrowed_cpu, uploaded_copy };

pub const Desc = struct {};

pub const UpdateDesc = struct {
    vertices: []const u8,
    indices: []const Index = &.{},
    vertex_stride: usize,
};
