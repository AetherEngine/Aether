const std = @import("std");
const Mat4 = @import("../math/math.zig").Mat4;
const Pipeline = @import("pipeline.zig");
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;

pub const Primitive = enum {
    triangles,
    lines,
};

/// A generic mesh parameterised by vertex type `V`.
///
/// Vertex data is stored in `vertices` (an unmanaged ArrayList backed by the
/// render pool). Use `append` to add vertices without touching the allocator
/// directly. `update` must be called after any change to push data to the GPU.
pub fn Mesh(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Vertex = V;

        handle:    Handle,
        vertices:  std.ArrayList(Vertex),
        primitive: Primitive = .triangles,

        pub fn new(pipeline: Pipeline.Handle) !Self {
            return .{
                .handle   = try gfx.api.tab.create_mesh(gfx.api.ptr, pipeline),
                .vertices = try std.ArrayList(V).initCapacity(Util.allocator(.render), 32),
            };
        }

        pub fn deinit(self: *Self) void {
            gfx.api.tab.destroy_mesh(gfx.api.ptr, self.handle);
            self.vertices.deinit(Util.allocator(.render));
            self.handle = 0;
        }

        /// Append a slice of vertices, growing the render-pool buffer as needed.
        pub fn append(self: *Self, verts: []const V) !void {
            try self.vertices.appendSlice(Util.allocator(.render), verts);
        }

        /// Push the current vertex data to the GPU. Call after any `append` or
        /// direct modification of `vertices.items`.
        pub fn update(self: *Self) void {
            gfx.api.tab.update_mesh(
                gfx.api.ptr, self.handle,
                std.mem.sliceAsBytes(self.vertices.items),
            );
        }

        pub fn draw(self: *Self, mat: *const Mat4) void {
            gfx.api.tab.draw_mesh(
                gfx.api.ptr, self.handle, mat, self.vertices.items.len, self.primitive,
            );
        }
    };
}
