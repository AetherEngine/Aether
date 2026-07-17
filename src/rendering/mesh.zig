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
pub const SourceMode = enum { borrowed_cpu, uploaded_copy };

pub const Desc = struct {};

pub const UpdateDesc = struct {
    vertices: []const u8,
    indices: []const Index = &.{},
    vertex_stride: usize,
};

pub const DataError = error{
    OutOfMemory,
    IndexOverflow,
};

/// CPU-side editable mesh data. On borrowed-source backends such as PSP and
/// 3DS, this data must remain alive while the uploaded Mesh uses it.
pub fn MeshData(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Vertex = V;

        vertices: std.ArrayList(Vertex),
        indices: std.ArrayList(Index),

        pub fn init(alloc: std.mem.Allocator) DataError!Self {
            var vertices = try std.ArrayList(V).initCapacity(alloc, 32);
            errdefer vertices.deinit(alloc);
            const indices = try std.ArrayList(Index).initCapacity(alloc, 32);
            return .{
                .vertices = vertices,
                .indices = indices,
            };
        }

        pub fn deinit(self: *Self, alloc: std.mem.Allocator) void {
            self.indices.deinit(alloc);
            self.vertices.deinit(alloc);
        }

        /// Append a slice of vertices, growing the buffer as needed.
        pub fn append(self: *Self, alloc: std.mem.Allocator, verts: []const V) DataError!void {
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

        pub fn ensure_tri_capacity(self: *Self, alloc: std.mem.Allocator, count: usize) DataError!void {
            const add_verts = count * 3;
            if (indexing_enabled) {
                if (self.vertices.items.len + add_verts > @as(usize, std.math.maxInt(Index)) + 1) return error.IndexOverflow;
                try self.indices.ensureTotalCapacity(alloc, self.indices.items.len + count * 3);
            }
            try self.vertices.ensureTotalCapacity(alloc, self.vertices.items.len + add_verts);
        }

        pub fn ensure_quad_capacity(self: *Self, alloc: std.mem.Allocator, count: usize) DataError!void {
            if (indexing_enabled) {
                const add_verts = count * 4;
                if (self.vertices.items.len + add_verts > @as(usize, std.math.maxInt(Index)) + 1) return error.IndexOverflow;
                try self.vertices.ensureTotalCapacity(alloc, self.vertices.items.len + add_verts);
                try self.indices.ensureTotalCapacity(alloc, self.indices.items.len + count * 6);
            } else {
                try self.vertices.ensureTotalCapacity(alloc, self.vertices.items.len + count * 6);
            }
        }

        pub inline fn add_tri(self: *Self, alloc: std.mem.Allocator, a: V, b: V, c: V) DataError!void {
            try self.ensure_tri_capacity(alloc, 1);
            self.add_tri_assume_capacity(a, b, c);
        }

        pub inline fn add_quad(self: *Self, alloc: std.mem.Allocator, a: V, b: V, c: V, d: V) DataError!void {
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

        pub fn update_desc(self: *const Self) UpdateDesc {
            return .{
                .vertices = std.mem.sliceAsBytes(self.vertices.items),
                .indices = if (indexing_enabled) self.indices.items else &.{},
                .vertex_stride = @sizeOf(Vertex),
            };
        }
    };
}

/// A generic mesh parameterised by vertex type `V`.
pub fn Mesh(comptime V: type) type {
    return struct {
        const Self = @This();

        pub const Vertex = V;
        pub const Data = MeshData(V);

        handle: Handle,

        pub fn init(desc: *const Desc) @import("../platform/gfx_api.zig").CreateMeshError!Self {
            const handle = try gfx.api.create_mesh(desc);
            return .{
                .handle = handle,
            };
        }

        pub fn deinit(self: *Self) void {
            gfx.api.destroy_mesh(self.handle);
            self.handle = .none;
        }

        /// Push the current CPU data to the backend. On borrowed-source
        /// backends, the data must remain alive and stable after this call.
        pub fn update(self: *Self, data: *const Data) void {
            if (gfx.validate_mesh_updates_outside_frame and gfx.frame_active) {
                @panic("Rendering.Mesh.update called during an active frame; rebuild/upload meshes during update, not draw");
            }
            const desc = data.update_desc();
            gfx.api.update_mesh(self.handle, &desc);
        }

        pub fn draw(self: *Self, mat: *const Mat4) void {
            gfx.api.draw_mesh(self.handle, mat);
        }
    };
}

test "mesh triangle and quad helpers build expected geometry" {
    const TestVertex = extern struct { id: u32 };
    const TestData = MeshData(TestVertex);
    const alloc = std.testing.allocator;

    var mesh = try TestData.init(alloc);
    defer mesh.deinit(alloc);

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
