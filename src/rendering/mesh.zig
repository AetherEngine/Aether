const std = @import("std");
const Mat4 = @import("../math/math.zig").Mat4;
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;

/// A generic mesh parameterised by vertex type `V`.
///
/// Vertex data is stored in `vertices` (an unmanaged ArrayList backed by the
/// caller-supplied allocator). Use `append` to add vertices without touching
/// the allocator directly. `update` must be called after any change to push
/// data to the GPU.
pub fn Mesh(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Vertex = V;

        handle: Handle,
        vertices: std.ArrayList(Vertex),

        pub fn new(alloc: std.mem.Allocator) !Self {
            return .{
                .handle = try gfx.api.create_mesh(),
                .vertices = try std.ArrayList(V).initCapacity(alloc, 32),
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            gfx.api.destroy_mesh(self.handle);
            self.vertices.deinit(alloc);
            self.handle = 0;
        }

        /// Append a slice of vertices, growing the buffer as needed.
        pub fn append(self: *Self, alloc: std.mem.Allocator, verts: []const V) !void {
            try self.vertices.appendSlice(alloc, verts);
        }

        /// Push the current vertex data to the GPU. Call after any `append` or
        /// direct modification of `vertices.items`.
        pub fn update(self: *Self) void {
            if (gfx.validate_mesh_updates_outside_frame and gfx.frame_active) {
                @panic("Rendering.Mesh.update called during an active frame; rebuild/upload meshes during update, not draw");
            }
            gfx.api.update_mesh(
                self.handle,
                std.mem.sliceAsBytes(self.vertices.items),
            );
        }

        pub fn draw(self: *Self, mat: *const Mat4) void {
            gfx.api.draw_mesh(
                self.handle,
                mat,
                self.vertices.items.len,
            );
        }
    };
}
