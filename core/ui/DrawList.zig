//! Bounded, insertion-ordered UI commands. Text is copied; textures, fonts, and
//! renderer registrations must outlive preparation/drawing. Mutations invalidate
//! prepared geometry. All coordinates and clips are logical pixels.
const std = @import("std");
const layout = @import("layout.zig");
const SpriteBatcher = @import("SpriteBatcher.zig");
const FontBatcher = @import("FontBatcher.zig");
const Custom = @import("custom_renderable.zig");
const Rendering = @import("../rendering/rendering.zig");
const Color = @import("Color.zig").Color;
const texture_region = @import("texture_region.zig");
const Math = @import("platform").math;
const List = @This();

pub const Limits = struct { commands: usize = 256, text_bytes: usize = 8192, clip_depth: usize = 16 };
pub const Error = error{ CommandCapacity, TextCapacity, ClipCapacity, ClipUnderflow, UnclosedClips, InvalidBounds, InvalidRange, MissingRenderer, UnsupportedCustomClip };
pub const Rect = struct { bounds: layout.LogicalRect, color: Color, layer: u8 = 0 };
pub const Text = struct { font: *const FontBatcher, entry: FontBatcher.TextEntry };
pub const Command = struct {
    clip: ?layout.LogicalRect,
    value: union(enum) { sprite: SpriteBatcher.Sprite, rect: Rect, text: Text, custom: Custom.Command },
};

allocator: std.mem.Allocator,
commands: []Command,
text_buffer: []u8,
clips: []layout.LogicalRect,
count: usize = 0,
text_used: usize = 0,
clip_count: usize = 0,

pub fn init(allocator: std.mem.Allocator, limits: Limits) !List {
    const commands = try allocator.alloc(Command, limits.commands);
    errdefer allocator.free(commands);
    const text_buffer = try allocator.alloc(u8, limits.text_bytes);
    errdefer allocator.free(text_buffer);
    return .{ .allocator = allocator, .commands = commands, .text_buffer = text_buffer, .clips = try allocator.alloc(layout.LogicalRect, limits.clip_depth) };
}
pub fn deinit(self: *List) void {
    self.allocator.free(self.commands);
    self.allocator.free(self.text_buffer);
    self.allocator.free(self.clips);
    self.* = undefined;
}
pub fn clear(self: *List) void {
    self.count = 0;
    self.text_used = 0;
    self.clip_count = 0;
}
pub fn current_clip(self: *const List) ?layout.LogicalRect {
    return if (self.clip_count > 0) self.clips[self.clip_count - 1] else null;
}
pub fn push_clip(self: *List, bounds: layout.LogicalRect) Error!void {
    try validate_rect(bounds);
    if (self.clip_count == self.clips.len) return error.ClipCapacity;
    self.clips[self.clip_count] = layout.intersection(bounds, self.current_clip());
    self.clip_count += 1;
}
pub fn pop_clip(self: *List) Error!void {
    if (self.clip_count == 0) return error.ClipUnderflow;
    self.clip_count -= 1;
}
fn append(self: *List, value: @FieldType(Command, "value")) Error!void {
    if (self.count == self.commands.len) return error.CommandCapacity;
    self.commands[self.count] = .{ .clip = self.current_clip(), .value = value };
    self.count += 1;
}
pub fn add_sprite(self: *List, value: SpriteBatcher.Sprite) Error!void {
    if (value.pos_extent.x < 0 or value.pos_extent.y < 0 or value.texture.width == 0 or value.texture.height == 0) return error.InvalidBounds;
    try self.append(.{ .sprite = value });
}
/// Draws a textured region using stretch, center elision, or a nine-slice.
/// Capacity and dimensions are checked before any pieces are appended.
pub fn add_region(self: *List, texture: *const Rendering.Texture, region: texture_region.TextureRegion, bounds: layout.LogicalRect, color: Color, layer: u8, sizing: texture_region.TextureSizing) Error!void {
    try validate_rect(bounds);
    if (region.w <= 0 or region.h <= 0 or texture.width == 0 or texture.height == 0) return error.InvalidBounds;
    _ = try sum(region.x, region.w);
    _ = try sum(region.y, region.h);
    var pieces: [9]SpriteBatcher.Sprite = undefined;
    var count: usize = 0;
    switch (sizing) {
        .stretch => {
            pieces[0] = region_sprite(texture, region, bounds, color, layer);
            count = 1;
        },
        .center_elide => |params| {
            if (params.min_w < 2 or bounds.width() < params.min_w or bounds.width() > params.max_w or region.w < bounds.width() or region.w > params.max_w) return error.InvalidBounds;
            const spans = texture_region.elide_center(region, bounds.width(), params);
            const middle = try sum(bounds.x0, spans.left.w);
            pieces[0] = region_sprite(texture, spans.left, .{ .x0 = bounds.x0, .y0 = bounds.y0, .x1 = middle, .y1 = bounds.y1 }, color, layer);
            pieces[1] = region_sprite(texture, spans.right, .{ .x0 = middle, .y0 = bounds.y0, .x1 = bounds.x1, .y1 = bounds.y1 }, color, layer);
            count = 2;
        },
        .nine_slice => |slice| {
            if (slice.left < 0 or slice.right < 0 or slice.top < 0 or slice.bottom < 0 or @as(i32, slice.left) + slice.right > Math.min(region.w, bounds.width()) or @as(i32, slice.top) + slice.bottom > Math.min(region.h, bounds.height())) return error.InvalidBounds;
            const source_x = [4]i16{ region.x, try sum(region.x, slice.left), try sum(region.x, region.w - slice.right), try sum(region.x, region.w) };
            const source_y = [4]i16{ region.y, try sum(region.y, slice.top), try sum(region.y, region.h - slice.bottom), try sum(region.y, region.h) };
            const dest_x = [4]i16{ bounds.x0, try sum(bounds.x0, slice.left), bounds.x1 - slice.right, bounds.x1 };
            const dest_y = [4]i16{ bounds.y0, try sum(bounds.y0, slice.top), bounds.y1 - slice.bottom, bounds.y1 };
            for (0..3) |y| for (0..3) |x| {
                if (dest_x[x] == dest_x[x + 1] or dest_y[y] == dest_y[y + 1]) continue;
                pieces[count] = region_sprite(texture, .{ .x = source_x[x], .y = source_y[y], .w = source_x[x + 1] - source_x[x], .h = source_y[y + 1] - source_y[y] }, .{ .x0 = dest_x[x], .y0 = dest_y[y], .x1 = dest_x[x + 1], .y1 = dest_y[y + 1] }, color, layer);
                count += 1;
            };
        },
    }
    if (count > self.commands.len - self.count) return error.CommandCapacity;
    for (pieces[0..count]) |piece| try self.add_sprite(piece);
}
fn region_sprite(texture: *const Rendering.Texture, region: texture_region.TextureRegion, bounds: layout.LogicalRect, color: Color, layer: u8) SpriteBatcher.Sprite {
    return .{ .texture = texture, .pos_offset = .{ .x = bounds.x0, .y = bounds.y0 }, .pos_extent = .{ .x = bounds.width(), .y = bounds.height() }, .tex_offset = .{ .x = region.x, .y = region.y }, .tex_extent = .{ .x = region.w, .y = region.h }, .color = color, .layer = layer };
}
pub fn add_rect(self: *List, bounds: layout.LogicalRect, color: Color, layer: u8) Error!void {
    try validate_rect(bounds);
    try self.append(.{ .rect = .{ .bounds = bounds, .color = color, .layer = layer } });
}
pub fn add_text(self: *List, font: *const FontBatcher, value: FontBatcher.TextEntry) Error!void {
    if (value.scale == 0) return error.InvalidBounds;
    if (value.str.len == 0) return;
    if (self.count == self.commands.len) return error.CommandCapacity;
    if (value.str.len > self.text_buffer.len - self.text_used) return error.TextCapacity;
    var copied = value;
    const dest = self.text_buffer[self.text_used..][0..value.str.len];
    @memcpy(dest, value.str);
    copied.str = dest;
    if (self.current_clip()) |clip| copied.clip = layout.intersection(clip, copied.clip);
    try self.append(.{ .text = .{ .font = font, .entry = copied } });
    self.text_used += dest.len;
}
pub fn add_custom(self: *List, command: Custom.Command) Error!void {
    try validate_rect(command.bounds);
    try self.append(.{ .custom = command });
}

/// Deferred layout translation. Overflow is checked before any command changes.
/// Clips captured by commands in the range move with their geometry.
pub fn offset_range(self: *List, first: usize, end: usize, offset: layout.Point) Error!void {
    if (first > end or end > self.count) return error.InvalidRange;
    for (self.commands[first..end]) |command| {
        var trial = command;
        try translate(&trial, offset);
    }
    for (self.commands[first..end]) |*command| try translate(command, offset);
}
fn translate(command: *Command, offset: layout.Point) Error!void {
    if (command.clip) |*clip| try translate_rect(clip, offset);
    switch (command.value) {
        .rect => |*rect| try translate_rect(&rect.bounds, offset),
        .custom => |*custom| try translate_rect(&custom.bounds, offset),
        .sprite => |*sprite| {
            sprite.pos_offset.x = try sum(sprite.pos_offset.x, offset.x);
            sprite.pos_offset.y = try sum(sprite.pos_offset.y, offset.y);
        },
        .text => |*text| {
            text.entry.pos_x = try sum(text.entry.pos_x, offset.x);
            text.entry.pos_y = try sum(text.entry.pos_y, offset.y);
            if (text.entry.clip) |*clip| try translate_rect(clip, offset);
        },
    }
}
fn sum(a: i16, b: i16) Error!i16 {
    return std.math.add(i16, a, b) catch error.InvalidBounds;
}
fn translate_rect(rect: *layout.LogicalRect, offset: layout.Point) Error!void {
    rect.x0 = try sum(rect.x0, offset.x);
    rect.x1 = try sum(rect.x1, offset.x);
    rect.y0 = try sum(rect.y0, offset.y);
    rect.y1 = try sum(rect.y1, offset.y);
}
fn validate_rect(rect: layout.LogicalRect) Error!void {
    if (rect.x1 < rect.x0 or rect.y1 < rect.y0 or @as(i32, rect.x1) - rect.x0 > 32767 or @as(i32, rect.y1) - rect.y0 > 32767) return error.InvalidBounds;
}

/// Resolves custom clipping before invoking a renderer. `inherit` requires the
/// renderer to implement partial clips; `reject_bounds` draws only fully inside
/// commands; `none` deliberately bypasses clipping.
pub fn resolve_custom(command: Command, registry: *const Custom.Registry) Error!?Custom.Command {
    var custom = command.value.custom;
    const renderer = registry.get(custom.renderer) orelse return error.MissingRenderer;
    custom.resolved_clip = null;
    if (custom.clip == .none) return custom;
    if (command.clip) |clip| {
        const visible = layout.intersection(custom.bounds, clip);
        if (visible.x0 >= visible.x1 or visible.y0 >= visible.y1) return null;
        if (!layout.contains_rect(clip, custom.bounds)) {
            if (custom.clip == .reject_bounds) return null;
            if (!renderer.supports_clipping) return error.UnsupportedCustomClip;
        }
        custom.resolved_clip = clip;
    }
    return custom;
}

pub const Prepared = struct {
    const Geometry = struct { data: SpriteBatcher.BatchMeshData, mesh: SpriteBatcher.BatchMesh, texture: *const Rendering.Texture, signature: ?u64 = null };
    const Entry = union(enum) { empty, geometry: Geometry, custom: Custom.Command };
    allocator: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    registry: *const Custom.Registry,
    valid: bool = false,

    pub fn deinit(self: *Prepared) void {
        for (self.entries.items) |*entry| switch (entry.*) {
            .geometry => |*geometry| {
                geometry.mesh.deinit();
                geometry.data.deinit(self.allocator);
            },
            .custom, .empty => {},
        };
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }
    /// Draw in a UI pass after clearing depth. Ordinary geometry disables depth
    /// writes, so later commands composite over earlier commands independent of
    /// their legacy layer field. Custom renderers must also disable depth writes,
    /// honor resolved_clip when present, and leave no out-of-bounds geometry.
    pub fn draw(self: *Prepared, base: *const Rendering.RenderState) void {
        if (!self.valid) return;
        var state = base.*;
        state.depth_write = false;
        state.cull = false;
        for (self.entries.items) |*entry| switch (entry.*) {
            .geometry => |*geometry| {
                state.texture = geometry.texture.handle;
                Rendering.set_state(&state);
                geometry.mesh.draw(&Math.Mat4.identity());
            },
            .empty => {},
            .custom => |*custom| self.registry.draw_group(@as(*const [1]Custom.Command, @ptrCast(custom)), base),
        };
    }
};

/// Prepare outside a graphics frame, then draw inside it. Output owns its meshes
/// and must be deinitialized outside a frame. A failed prepare publishes nothing.
/// Preparing another list with this registry replaces its custom renderer state.
/// Draw/release the previous prepared list before preparing the next one.
/// `white_texture` must be an opaque white texel/texture for solid rectangles.
pub fn prepare(self: *const List, allocator: std.mem.Allocator, registry: *const Custom.Registry, white_texture: *const Rendering.Texture, screen_width: u32, screen_height: u32, scale: u32) !Prepared {
    var result: Prepared = .{ .allocator = allocator, .registry = registry };
    errdefer result.deinit();
    try rebuild(self, &result, white_texture, screen_width, screen_height, scale);
    return result;
}

/// Reuses prepared meshes and CPU capacity across frames. Unchanged geometry
/// skips backend uploads. Call outside a graphics frame. On error the result
/// remains owned/deinitializable but draw is disabled until a successful rebuild.
pub fn rebuild(self: *const List, prepared: *Prepared, white_texture: *const Rendering.Texture, screen_width: u32, screen_height: u32, scale: u32) !void {
    prepared.valid = false;
    if (self.clip_count != 0) return error.UnclosedClips;
    if (scale == 0 or screen_width == 0 or screen_height == 0 or layout.logical_width(screen_width, scale) > 32767 or layout.logical_height(screen_height, scale) > 32767) return error.InvalidBounds;
    const registry = prepared.registry;
    const allocator = prepared.allocator;
    for (self.commands[0..self.count]) |command| if (command.value == .custom) {
        _ = try resolve_custom(command, registry);
    };
    registry.reset_all();
    errdefer registry.reset_all();
    try prepared.entries.ensureTotalCapacity(allocator, self.count);
    while (prepared.entries.items.len < self.count) prepared.entries.appendAssumeCapacity(.empty);
    while (prepared.entries.items.len > self.count) {
        var removed = prepared.entries.pop().?;
        if (removed == .geometry) {
            removed.geometry.mesh.deinit();
            removed.geometry.data.deinit(allocator);
        }
    }
    for (self.commands[0..self.count], prepared.entries.items) |command, *entry| {
        if (command.value == .custom) {
            if (entry.* == .geometry) {
                entry.geometry.mesh.deinit();
                entry.geometry.data.deinit(allocator);
            }
            entry.* = if (try resolve_custom(command, registry)) |custom| .{ .custom = custom } else .empty;
            continue;
        }
        if (entry.* != .geometry) {
            var data = try SpriteBatcher.BatchMeshData.init(allocator);
            errdefer data.deinit(allocator);
            entry.* = .{ .geometry = .{ .data = data, .mesh = try SpriteBatcher.BatchMesh.init(&.{}), .texture = white_texture } };
        }
        const data = &entry.geometry.data;
        const prior_vertices = data.vertices.items.ptr;
        const prior_indices = data.indices.items.ptr;
        data.clear_retaining_capacity();
        var texture = white_texture;
        switch (command.value) {
            .sprite => |sprite| {
                try data.ensure_quad_capacity(allocator, 1);
                SpriteBatcher.append_geometry(data, &sprite, screen_width, screen_height, scale, command.clip);
                texture = sprite.texture;
            },
            .text => |text| {
                try data.ensure_quad_capacity(allocator, std.math.mul(usize, text.entry.str.len, 2) catch return error.TextCapacity);
                text.font.append_geometry(data, &text.entry, screen_width, screen_height, scale);
                texture = text.font.texture;
            },
            .rect => |rect| {
                const sprite: SpriteBatcher.Sprite = .{ .texture = white_texture, .pos_offset = .{ .x = rect.bounds.x0, .y = rect.bounds.y0 }, .pos_extent = .{ .x = rect.bounds.width(), .y = rect.bounds.height() }, .tex_offset = .{ .x = 0, .y = 0 }, .tex_extent = .{ .x = 1, .y = 1 }, .color = rect.color, .layer = rect.layer };
                try data.ensure_quad_capacity(allocator, 1);
                SpriteBatcher.append_geometry(data, &sprite, screen_width, screen_height, scale, command.clip);
            },
            .custom => unreachable,
        }

        entry.geometry.texture = texture;
        var signature = std.hash.Wyhash.init(0);
        signature.update(std.mem.sliceAsBytes(data.vertices.items));
        signature.update(std.mem.sliceAsBytes(data.indices.items));
        const checksum = signature.final();
        if (entry.geometry.signature == null or entry.geometry.signature.? != checksum or prior_vertices != data.vertices.items.ptr or prior_indices != data.indices.items.ptr) {
            entry.geometry.mesh.update(data);
            entry.geometry.signature = checksum;
        }
    }
    for (prepared.entries.items) |*entry| if (entry.* == .custom) {
        const command = &entry.custom;
        const renderer = registry.get(command.renderer).?;
        try renderer.prepare(renderer.ctx, @as(*const [1]Custom.Command, @ptrCast(command)));
    };
    prepared.valid = true;
}
