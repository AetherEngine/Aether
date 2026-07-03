const std = @import("std");
const options = @import("options");
const Mat4 = @import("../math/math.zig").Mat4;
const Util = @import("../util/util.zig");
const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const MeshHandleTag = enum {};
pub const Handle = Util.Handle(MeshHandleTag);
pub const Index = u16;
pub const indexing_enabled = options.config.mesh_indexing;

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
        indices: std.ArrayList(Index),

        pub fn new(alloc: std.mem.Allocator) !Self {
            const handle = try gfx.api.create_mesh();
            errdefer gfx.api.destroy_mesh(handle);
            var vertices = try std.ArrayList(V).initCapacity(alloc, 32);
            errdefer vertices.deinit(alloc);
            const indices = try std.ArrayList(Index).initCapacity(alloc, 32);
            return .{
                .handle = handle,
                .vertices = vertices,
                .indices = indices,
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            gfx.api.destroy_mesh(self.handle);
            self.indices.deinit(alloc);
            self.vertices.deinit(alloc);
            self.handle = .none;
        }

        /// Append a slice of vertices, growing the buffer as needed.
        pub fn append(self: *Self, alloc: std.mem.Allocator, verts: []const V) !void {
            try self.vertices.appendSlice(alloc, verts);
        }

        pub fn clear_retaining_capacity(self: *Self) void {
            self.vertices.clearRetainingCapacity();
            self.indices.clearRetainingCapacity();
        }

        pub fn clear_and_free(self: *Self, alloc: std.mem.Allocator) void {
            self.vertices.clearAndFree(alloc);
            self.indices.clearAndFree(alloc);
        }

        pub fn ensure_tri_capacity(self: *Self, alloc: std.mem.Allocator, count: usize) !void {
            const add_verts = count * 3;
            if (indexing_enabled) {
                if (self.vertices.items.len + add_verts > @as(usize, std.math.maxInt(Index)) + 1) return error.IndexOverflow;
                try self.indices.ensureTotalCapacity(alloc, self.indices.items.len + count * 3);
            }
            try self.vertices.ensureTotalCapacity(alloc, self.vertices.items.len + add_verts);
        }

        pub fn ensure_quad_capacity(self: *Self, alloc: std.mem.Allocator, count: usize) !void {
            if (indexing_enabled) {
                const add_verts = count * 4;
                if (self.vertices.items.len + add_verts > @as(usize, std.math.maxInt(Index)) + 1) return error.IndexOverflow;
                try self.vertices.ensureTotalCapacity(alloc, self.vertices.items.len + add_verts);
                try self.indices.ensureTotalCapacity(alloc, self.indices.items.len + count * 6);
            } else {
                try self.vertices.ensureTotalCapacity(alloc, self.vertices.items.len + count * 6);
            }
        }

        pub inline fn add_tri(self: *Self, alloc: std.mem.Allocator, a: V, b: V, c: V) !void {
            try self.ensure_tri_capacity(alloc, 1);
            self.add_tri_assume_capacity(a, b, c);
        }

        pub inline fn add_quad(self: *Self, alloc: std.mem.Allocator, a: V, b: V, c: V, d: V) !void {
            try self.ensure_quad_capacity(alloc, 1);
            self.add_quad_assume_capacity(a, b, c, d);
        }

        pub inline fn add_tri_assume_capacity(self: *Self, a: V, b: V, c: V) void {
            if (indexing_enabled) {
                std.debug.assert(self.vertices.items.len <= std.math.maxInt(Index) - 2);
                const base: Index = @intCast(self.vertices.items.len);
                self.vertices.appendSliceAssumeCapacity(&.{ a, b, c });
                self.indices.appendSliceAssumeCapacity(&.{ base, base + 1, base + 2 });
            } else {
                self.vertices.appendSliceAssumeCapacity(&.{ a, b, c });
            }
        }

        pub inline fn add_quad_assume_capacity(self: *Self, a: V, b: V, c: V, d: V) void {
            if (indexing_enabled) {
                std.debug.assert(self.vertices.items.len <= std.math.maxInt(Index) - 3);
                const base: Index = @intCast(self.vertices.items.len);
                self.vertices.appendSliceAssumeCapacity(&.{ a, b, c, d });
                self.indices.appendSliceAssumeCapacity(&.{ base, base + 1, base + 2, base, base + 2, base + 3 });
            } else {
                self.vertices.appendSliceAssumeCapacity(&.{ a, b, c, a, c, d });
            }
        }

        /// Push the current vertex data to the GPU. Call after any `append` or
        /// direct modification of `vertices.items` or `indices.items`.
        pub fn update(self: *Self) void {
            if (gfx.validate_mesh_updates_outside_frame and gfx.frame_active) {
                @panic("Rendering.Mesh.update called during an active frame; rebuild/upload meshes during update, not draw");
            }
            gfx.api.update_mesh(
                self.handle,
                std.mem.sliceAsBytes(self.vertices.items),
                if (indexing_enabled) self.indices.items else &.{},
            );
        }

        pub fn draw(self: *Self, mat: *const Mat4) void {
            gfx.api.draw_mesh(
                self.handle,
                mat,
            );
        }
    };
}

test "mesh triangle and quad helpers build expected geometry" {
    const TestVertex = extern struct { id: u32 };
    const TestMesh = Mesh(TestVertex);
    const alloc = std.testing.allocator;

    var mesh: TestMesh = .{
        .handle = .none,
        .vertices = try std.ArrayList(TestVertex).initCapacity(alloc, 0),
        .indices = try std.ArrayList(Index).initCapacity(alloc, 0),
    };
    defer mesh.indices.deinit(alloc);
    defer mesh.vertices.deinit(alloc);

    try mesh.add_tri(alloc, .{ .id = 0 }, .{ .id = 1 }, .{ .id = 2 });
    try mesh.add_quad(alloc, .{ .id = 3 }, .{ .id = 4 }, .{ .id = 5 }, .{ .id = 6 });

    if (indexing_enabled) {
        try std.testing.expectEqual(@as(usize, 7), mesh.vertices.items.len);
        try std.testing.expectEqualSlices(Index, &.{ 0, 1, 2, 3, 4, 5, 3, 5, 6 }, mesh.indices.items);
    } else {
        try std.testing.expectEqual(@as(usize, 9), mesh.vertices.items.len);
        try std.testing.expectEqual(@as(usize, 0), mesh.indices.items.len);
        try std.testing.expectEqual(@as(u32, 3), mesh.vertices.items[3].id);
        try std.testing.expectEqual(@as(u32, 5), mesh.vertices.items[7].id);
    }
}
