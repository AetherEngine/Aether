//! Bounded world-space quad generation with reusable compact mesh storage.
//! Rebuild and upload before drawing. On borrowed-source backends, do not call
//! begin/add while a submitted mesh is still being consumed by the GPU.
const std = @import("std");
const Platform = @import("platform");
const Vec3 = Platform.math.Vec3;
const Mat4 = Platform.math.Mat4;
const vertex = Platform.graphics.vertex;
const mesh = @import("mesh.zig");
const BillboardBatcher = @This();

pub const Data = mesh.MeshDataType(vertex.Vertex);
pub const Mesh = mesh.MeshType(vertex.Vertex);
pub const Error = error{ BatchFull, InvalidBillboard, InvalidBasis, InvalidCapacity } || vertex.PositionEncoding.Error;
pub const Desc = struct {
    capacity: usize,
    /// Explicit precision/range tradeoff: 128 gives increments of 1/128 world
    /// unit and a local range just under +/-256. No game scale is assumed.
    units_per_world_unit: f32,
    normalization: vertex.PositionNormalization = vertex.native_position_normalization,
};
pub const Basis = struct {
    right: Vec3,
    up: Vec3,

    pub fn init(right: Vec3, up: Vec3) Error!Basis {
        const r = try unit(right);
        const u = try unit(up.sub(r.scale(up.dot(r))));
        return .{ .right = r, .up = u };
    }

    /// Extracts world-space camera axes from a rigid row-vector view matrix.
    /// Camera roll is retained; callers may supply their own axes to omit it.
    pub fn from_view(view: Mat4) Error!Basis {
        return Basis.init(Vec3.new(view.data[0][0], view.data[1][0], view.data[2][0]), Vec3.new(view.data[0][1], view.data[1][1], view.data[2][1]));
    }
};
pub const Facing = union(enum) {
    camera_plane,
    /// Rotates around world +Y to face the supplied camera position. Directly
    /// vertical views fall back to the begin() basis projected onto XZ.
    axis_y: Vec3,
    fixed: Basis,
};
pub const UvRegion = struct {
    /// Packed UVs match Rendering.Vertex and Ui.TextureAtlas tile regions.
    min: [2]i16 = .{ 0, 0 },
    max: [2]i16 = .{ 32767, 32767 },
};
pub const Billboard = struct {
    position: Vec3,
    /// Full width and height in world units.
    size: [2]f32,
    uv: UvRegion = .{},
    color: u32 = 0xffffffff,
    facing: Facing = .camera_plane,
};

allocator: std.mem.Allocator,
data: Data,
gpu_mesh: ?Mesh = null,
capacity: usize,
count: usize = 0,
encoding: vertex.PositionEncoding,
origin: Vec3 = Vec3.zero(),
basis: Basis = .{ .right = Vec3.new(1, 0, 0), .up = Vec3.new(0, 1, 0) },

/// Allocates all CPU geometry storage up front. GPU creation is deferred until
/// upload(), so mesh generation and tests do not require a graphics context.
pub fn init(allocator: std.mem.Allocator, desc: Desc) (Error || mesh.DataError)!BillboardBatcher {
    if (desc.capacity == 0 or desc.capacity > std.math.maxInt(usize) / (6 * @sizeOf(vertex.Vertex))) return error.InvalidCapacity;
    if (mesh.indexing_enabled and desc.capacity > (@as(usize, std.math.maxInt(mesh.Index)) + 1) / 4) return error.InvalidCapacity;
    const encoding = try vertex.PositionEncoding.init(desc.units_per_world_unit, desc.normalization);
    var data = try Data.init(allocator);
    errdefer data.deinit(allocator);

    try data.ensure_quad_capacity(allocator, desc.capacity);
    return .{ .allocator = allocator, .data = data, .capacity = desc.capacity, .encoding = encoding };
}

pub fn deinit(self: *BillboardBatcher) void {
    if (self.gpu_mesh) |*gpu_mesh| gpu_mesh.deinit();
    self.data.deinit(self.allocator);
    self.* = undefined;
}

/// Starts a new batch without reallocating. Choose a nearby world origin to
/// keep compact positions in range; draw() supplies its model translation.
pub fn begin(self: *BillboardBatcher, origin: Vec3, basis: Basis) Error!void {
    if (!finite(origin)) return error.InvalidBillboard;
    const normalized = try Basis.init(basis.right, basis.up);
    self.data.clear_retaining_capacity();
    self.count = 0;
    self.origin = origin;
    self.basis = normalized;
}

/// Rejects capacity, invalid data or any out-of-range corner before appending
/// geometry. The caller may skip PositionOutOfRange to cull a distant effect.
pub fn add(self: *BillboardBatcher, billboard: Billboard) Error!void {
    if (self.count >= self.capacity) return error.BatchFull;
    if (!finite(billboard.position) or !std.math.isFinite(billboard.size[0]) or !std.math.isFinite(billboard.size[1]) or
        billboard.size[0] <= 0 or billboard.size[1] <= 0) return error.InvalidBillboard;
    const basis = switch (billboard.facing) {
        .camera_plane => self.basis,
        .fixed => |basis| try Basis.init(basis.right, basis.up),
        .axis_y => |camera| blk: {
            if (!finite(camera)) return error.InvalidBillboard;
            const normal = Vec3.new(camera.x - billboard.position.x, 0, camera.z - billboard.position.z);
            const right = if (normal.length_sq() > 0.000001)
                Vec3.new(normal.z, 0, -normal.x)
            else
                Vec3.new(self.basis.right.x, 0, self.basis.right.z);
            break :blk try Basis.init(right, Vec3.new(0, 1, 0));
        },
    };
    const right = basis.right.scale(billboard.size[0] * 0.5);
    const up = basis.up.scale(billboard.size[1] * 0.5);
    const center = billboard.position.sub(self.origin);
    const positions = [4][3]i16{
        try self.encoding.encode(center.sub(right).sub(up)),
        try self.encoding.encode(center.add(right).sub(up)),
        try self.encoding.encode(center.add(right).add(up)),
        try self.encoding.encode(center.sub(right).add(up)),
    };
    const uv = billboard.uv;
    self.data.add_quad_assume_capacity(
        .{ .pos = positions[0], .color = billboard.color, .uv = .{ uv.min[0], uv.max[1] } },
        .{ .pos = positions[1], .color = billboard.color, .uv = .{ uv.max[0], uv.max[1] } },
        .{ .pos = positions[2], .color = billboard.color, .uv = .{ uv.max[0], uv.min[1] } },
        .{ .pos = positions[3], .color = billboard.color, .uv = .{ uv.min[0], uv.min[1] } },
    );
    self.count += 1;
}

pub fn upload(self: *BillboardBatcher) Platform.gfx_api.CreateMeshError!void {
    if (self.gpu_mesh == null) self.gpu_mesh = try Mesh.init(&.{});
    self.gpu_mesh.?.update(&self.data);
}

pub fn model_matrix(self: *const BillboardBatcher) Mat4 {
    const scale = self.encoding.model_scale();
    return Mat4.scaling(scale, scale, scale).mul(Mat4.translation(self.origin.x, self.origin.y, self.origin.z));
}

/// Uses the caller's current render state/texture. Call upload() after editing.
pub fn draw(self: *BillboardBatcher) void {
    if (self.count == 0) return;
    if (self.gpu_mesh) |*gpu_mesh| {
        const model = self.model_matrix();
        gpu_mesh.draw(&model);
    }
}

fn unit(vector: Vec3) Error!Vec3 {
    if (!finite(vector)) return error.InvalidBasis;
    const length = vector.length();
    if (!std.math.isFinite(length) or length <= 0.000001) return error.InvalidBasis;
    return vector.scale(1 / length);
}

fn finite(vector: Vec3) bool {
    return std.math.isFinite(vector.x) and std.math.isFinite(vector.y) and std.math.isFinite(vector.z);
}

test "billboards reuse bounded storage with origin-relative compact positions" {
    var batch = try init(std.testing.allocator, .{ .capacity = 1, .units_per_world_unit = 128 });
    defer batch.deinit();

    const original_storage = batch.data.vertices.items.ptr;
    const basis = try Basis.from_view(Mat4.identity());
    try batch.begin(Vec3.new(10000, 20, 10000), basis);
    const quad: Billboard = .{ .position = Vec3.new(10001, 22, 10000), .size = .{ 2, 2 }, .color = 0xff123456 };
    try batch.add(quad);
    try std.testing.expectEqual(@as(usize, if (mesh.indexing_enabled) 4 else 6), batch.data.vertices.items.len);
    try std.testing.expectEqual(@as(usize, if (mesh.indexing_enabled) 6 else 0), batch.data.indices.items.len);
    try std.testing.expectEqual([3]i16{ 0, 128, 0 }, batch.data.vertices.items[0].pos);
    try std.testing.expectEqual(@as(u32, 0xff123456), batch.data.vertices.items[0].color);
    try std.testing.expectError(error.BatchFull, batch.add(quad));
    try batch.begin(Vec3.zero(), basis);
    try std.testing.expectError(error.PositionOutOfRange, batch.add(quad));
    try std.testing.expectEqual(@as(usize, 0), batch.data.vertices.items.len);
    try std.testing.expectEqual(original_storage, batch.data.vertices.items.ptr);
    try batch.add(.{ .position = Vec3.zero(), .size = .{ 2, 2 }, .facing = .{ .axis_y = Vec3.new(5, 0, 0) } });
    try std.testing.expectEqual([3]i16{ 0, -128, 128 }, batch.data.vertices.items[0].pos);
    try std.testing.expectError(error.InvalidBasis, Basis.init(Vec3.one(), Vec3.one()));
}
