const std = @import("std");
const assert = std.debug.assert;
const options = @import("options");
const Math = @import("platform").math;
const Rendering = @import("../rendering/rendering.zig");

const Scaling = @import("Scaling.zig");
const layout = @import("layout.zig");
const texture_region = @import("texture_region.zig");

pub const Color = @import("Color.zig").Color;
pub const Vertex = Rendering.Vertex;
pub const BatchMesh = Rendering.MeshType(Vertex);
pub const BatchMeshData = Rendering.MeshDataType(Vertex);

const SpriteBatcher = @This();

pub const Anchor = layout.Anchor;
pub const TextureRegion = texture_region.TextureRegion;
pub const CenterElide = texture_region.CenterElide;

pub const Sprite = extern struct {
    pub const Range = extern struct { x: i16, y: i16 };

    texture: *const Rendering.Texture,
    pos_offset: Range,
    pos_extent: Range,
    tex_offset: Range,
    tex_extent: Range,
    color: Color,
    layer: u8,
    reference: Anchor = .top_left,
    origin: Anchor = .top_left,
    _pad: u8 = 0,

    comptime {
        assert(@sizeOf(Sprite) == @sizeOf(*anyopaque) + 24);
    }
};

const TextureBatch = struct {
    texture: *const Rendering.Texture,
    mesh_data: BatchMeshData,
    mesh: BatchMesh,
};

const max_sprites: u16 = if (options.config.platform == .psp) 256 else 1024;

sprites: [2][max_sprites]Sprite,
count: u16,
prev_count: u16,
current: u1,
last_screen_w: u32,
last_screen_h: u32,
batches: std.ArrayList(TextureBatch),
allocator: std.mem.Allocator,

pub fn init(allocator: std.mem.Allocator) !SpriteBatcher {
    return SpriteBatcher{
        .sprites = undefined,
        .count = 0,
        .prev_count = 0,
        .current = 0,
        .last_screen_w = 0,
        .last_screen_h = 0,
        .batches = try std.ArrayList(TextureBatch).initCapacity(allocator, 4),
        .allocator = allocator,
    };
}

pub fn deinit(self: *SpriteBatcher) void {
    defer self.* = undefined;

    for (self.batches.items) |*batch| {
        batch.mesh.deinit();
        batch.mesh_data.deinit(self.allocator);
    }
    self.batches.deinit(self.allocator);
}

pub fn add_sprite(self: *SpriteBatcher, sprite: *const Sprite) void {
    assert(self.count < max_sprites);
    self.sprites[self.current][self.count] = sprite.*;
    self.count += 1;
}

pub const ElidedSprite = struct {
    texture: *const Rendering.Texture,
    region: TextureRegion,
    pos_offset: layout.Point,
    dst_w: i16,
    dst_h: i16,
    color: Color,
    layer: u8,
    reference: Anchor = .top_left,
    origin: Anchor = .top_left,
    sizing: CenterElide = .{},
};

pub fn add_sprite_elided(self: *SpriteBatcher, sprite: *const ElidedSprite) void {
    assert(sprite.dst_w > 0);
    assert(sprite.dst_h > 0);

    const spans = texture_region.elide_center(sprite.region, sprite.dst_w, sprite.sizing);

    // Anchor the combined box before splitting it, keeping both halves aligned.
    const orig = layout.anchor_point(sprite.origin, sprite.dst_w, sprite.dst_h);
    const base_x: i16 = sprite.pos_offset.x - orig.x;
    const base_y: i16 = sprite.pos_offset.y - orig.y;

    self.add_sprite(&.{
        .texture = sprite.texture,
        .pos_offset = .{ .x = base_x, .y = base_y },
        .pos_extent = .{ .x = spans.left.w, .y = sprite.dst_h },
        .tex_offset = .{ .x = spans.left.x, .y = spans.left.y },
        .tex_extent = .{ .x = spans.left.w, .y = spans.left.h },
        .color = sprite.color,
        .layer = sprite.layer,
        .reference = sprite.reference,
        .origin = .top_left,
    });
    self.add_sprite(&.{
        .texture = sprite.texture,
        .pos_offset = .{ .x = base_x + spans.left.w, .y = base_y },
        .pos_extent = .{ .x = spans.right.w, .y = sprite.dst_h },
        .tex_offset = .{ .x = spans.right.x, .y = spans.right.y },
        .tex_extent = .{ .x = spans.right.w, .y = spans.right.h },
        .color = sprite.color,
        .layer = sprite.layer,
        .reference = sprite.reference,
        .origin = .top_left,
    });
}

pub fn clear(self: *SpriteBatcher) void {
    self.prev_count = self.count;
    self.current ^= 1;
    self.count = 0;
}

pub fn update(self: *SpriteBatcher) !void {
    if (self.count == 0) return;

    const size = Rendering.surface_size();
    const screen_w = size.width;
    const screen_h = size.height;

    std.sort.insertion(Sprite, self.sprites[self.current][0..self.count], {}, sprite_before);

    const curr = std.mem.sliceAsBytes(self.sprites[self.current][0..self.count]);
    const prev = std.mem.sliceAsBytes(self.sprites[self.current ^ 1][0..self.prev_count]);
    const sprites_changed = !std.mem.eql(u8, curr, prev);
    const size_changed = screen_w != self.last_screen_w or screen_h != self.last_screen_h;

    if (sprites_changed or size_changed) {
        try self.rebuild_batches(screen_w, screen_h);
        self.last_screen_w = screen_w;
        self.last_screen_h = screen_h;
    }
}

pub fn draw(self: *SpriteBatcher) void {
    if (self.count == 0) return;

    const ident = Math.Mat4.identity();
    for (self.batches.items) |*batch| {
        Rendering.set_state(&.{ .texture = batch.texture.handle });
        batch.mesh.draw(&ident);
    }
}

pub fn flush(self: *SpriteBatcher) !void {
    try self.update();
    self.draw();
}

fn rebuild_batches(self: *SpriteBatcher, screen_w: u32, screen_h: u32) !void {
    const sprites = self.sprites[self.current][0..self.count];
    const scale = Scaling.compute(screen_w, screen_h);
    var batch_idx: u16 = 0;
    var i: u16 = 0;

    while (i < self.count) {
        const tex = sprites[i].texture;
        const group_start = i;
        while (i < self.count and sprites[i].texture == tex) : (i += 1) {}
        const group_count: u16 = i - group_start;

        if (batch_idx >= self.batches.items.len) {
            var mesh_data = try BatchMeshData.init(self.allocator);
            errdefer mesh_data.deinit(self.allocator);
            var mesh = try BatchMesh.init(&.{});
            errdefer mesh.deinit();
            try self.batches.append(self.allocator, .{ .texture = tex, .mesh_data = mesh_data, .mesh = mesh });
        }

        var batch = &self.batches.items[batch_idx];
        batch.texture = tex;
        batch.mesh_data.clear_retaining_capacity();
        try batch.mesh_data.ensure_quad_capacity(self.allocator, group_count);

        for (sprites[group_start..i]) |sprite| {
            emit_sprite_vertices(&batch.mesh_data, &sprite, screen_w, screen_h, scale);
        }

        batch.mesh.update(&batch.mesh_data);
        batch_idx += 1;
    }

    while (self.batches.items.len > batch_idx) {
        var old = self.batches.pop().?;
        old.mesh.deinit();
        old.mesh_data.deinit(self.allocator);
    }
}

fn emit_sprite_vertices(mesh: *BatchMeshData, sprite: *const Sprite, screen_w: u32, screen_h: u32, scale: u32) void {
    append_geometry(mesh, sprite, screen_w, screen_h, scale, null);
}

/// Appends at most one quad. Caller reserves quad capacity first. Anchors and
/// clipping are resolved before proportional texture coordinates are generated.
pub fn append_geometry(mesh: *BatchMeshData, sprite: *const Sprite, screen_w: u32, screen_h: u32, scale: u32, clip: ?layout.LogicalRect) void {
    const max_lx: i16 = @intCast(layout.logical_width(screen_w, scale));
    const max_ly: i16 = @intCast(layout.logical_height(screen_h, scale));

    const ref = layout.anchor_point(sprite.reference, max_lx, max_ly);
    const orig = layout.anchor_point(sprite.origin, sprite.pos_extent.x, sprite.pos_extent.y);
    const raw_x0: i32 = @as(i32, ref.x) + sprite.pos_offset.x - orig.x;
    const raw_y0: i32 = @as(i32, ref.y) + sprite.pos_offset.y - orig.y;
    const bounds = layout.intersection(.{ .x0 = 0, .y0 = 0, .x1 = max_lx, .y1 = max_ly }, clip);
    const x0: i16 = @intCast(@min(bounds.x1, @max(raw_x0, bounds.x0)));
    const y0: i16 = @intCast(@min(bounds.y1, @max(raw_y0, bounds.y0)));
    const x1: i16 = @intCast(@max(bounds.x0, @min(raw_x0 + sprite.pos_extent.x, bounds.x1)));
    const y1: i16 = @intCast(@max(bounds.y0, @min(raw_y0 + sprite.pos_extent.y, bounds.y1)));

    if (x0 >= x1 or y0 >= y1) return;

    const sx0 = logical_to_snorm_x(x0, screen_w, scale);
    const sy0 = logical_to_snorm_y(y0, screen_h, scale);
    const sx1 = logical_to_snorm_x(x1, screen_w, scale);
    const sy1 = logical_to_snorm_y(y1, screen_h, scale);
    // Higher layers have smaller depth and pass the less-than depth test.
    const z: i16 = 32766 - @as(i16, sprite.layer);

    // UVs stay relative to the unclipped sprite origin.
    const irx: i32 = raw_x0;
    const iry: i32 = raw_y0;
    const iw: i32 = sprite.pos_extent.x;
    const ih: i32 = sprite.pos_extent.y;
    const uv_l = texel_to_snorm(@as(i32, sprite.tex_offset.x) + @divTrunc(@as(i32, sprite.tex_extent.x) * (@as(i32, x0) - irx), iw), sprite.texture.width);
    const uv_t = texel_to_snorm(@as(i32, sprite.tex_offset.y) + @divTrunc(@as(i32, sprite.tex_extent.y) * (@as(i32, y0) - iry), ih), sprite.texture.height);
    const uv_r = texel_to_snorm(@as(i32, sprite.tex_offset.x) + @divTrunc(@as(i32, sprite.tex_extent.x) * (@as(i32, x1) - irx), iw), sprite.texture.width);
    const uv_b = texel_to_snorm(@as(i32, sprite.tex_offset.y) + @divTrunc(@as(i32, sprite.tex_extent.y) * (@as(i32, y1) - iry), ih), sprite.texture.height);

    const color: u32 = @bitCast(sprite.color);

    mesh.add_quad_assume_capacity(
        .{ .pos = .{ sx0, sy0, z }, .uv = .{ uv_l, uv_t }, .color = color },
        .{ .pos = .{ sx0, sy1, z }, .uv = .{ uv_l, uv_b }, .color = color },
        .{ .pos = .{ sx1, sy1, z }, .uv = .{ uv_r, uv_b }, .color = color },
        .{ .pos = .{ sx1, sy0, z }, .uv = .{ uv_r, uv_t }, .color = color },
    );
}

const logical_to_snorm_x = layout.logical_to_snorm_x;
const logical_to_snorm_y = layout.logical_to_snorm_y;

fn texel_to_snorm(texel: i32, dim: u32) i16 {
    return @intCast(@divTrunc(texel * 32767, @as(i32, @intCast(dim))));
}

fn sprite_before(_: void, a: Sprite, b: Sprite) bool {
    if (a.layer != b.layer) return a.layer < b.layer;
    return @intFromPtr(a.texture) < @intFromPtr(b.texture);
}

test "sprite clips resolve non top-left anchors and proportional UVs" {
    var texture: Rendering.Texture = undefined;
    texture.width = 100;
    texture.height = 100;
    var data = try BatchMeshData.init(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    try data.ensure_quad_capacity(std.testing.allocator, 1);
    append_geometry(&data, &.{ .texture = &texture, .pos_offset = .{ .x = 0, .y = 0 }, .pos_extent = .{ .x = 20, .y = 20 }, .tex_offset = .{ .x = 0, .y = 0 }, .tex_extent = .{ .x = 100, .y = 100 }, .color = Color.rgba(255, 255, 255, 255), .layer = 0, .reference = .middle_center, .origin = .middle_center }, 100, 100, 1, .{ .x0 = 45, .y0 = 45, .x1 = 55, .y1 = 55 });
    try std.testing.expect(data.vertices.items.len >= 4);
    try std.testing.expectEqual(@as(i16, 8191), data.vertices.items[0].uv[0]);
    try std.testing.expectEqual(@as(i16, 8191), data.vertices.items[0].uv[1]);
}
