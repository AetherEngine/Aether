//! Mesh resources exchanged between Core and graphics backends.
const HandleType = @import("../util/handle.zig").HandleType;

pub const MeshHandleTag = enum {};
pub const Handle = HandleType(MeshHandleTag);
pub const Index = u16;
pub const indexing_enabled = @import("options").config.mesh_indexing;

/// Borrowed sources must remain alive and unchanged until the backend is done
/// consuming them. Uploaded copies no longer depend on the source after update.
pub const SourceMode = enum { borrowed_cpu, uploaded_copy };

/// How a borrowed-source backend may treat the CPU data behind a mesh while the GPU draws one frame as the CPU prepares the next.
pub const Retention = enum {
    /// Rewritten freely: overlapping backends copy it into per-frame storage when drawn.
    dynamic,
    /// Never changed after its update: always borrowed.
    static,
    /// The application leaves the data unchanged until `gpu_fence_passed` for a `gpu_fence` taken when it was last drawn.
    fenced,
};

pub const Desc = struct {
    retention: Retention = .dynamic,
};

pub const UpdateDesc = struct {
    vertices: []const u8,
    indices: []const Index = &.{},
    vertex_stride: usize,
};
