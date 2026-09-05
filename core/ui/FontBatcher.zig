const std = @import("std");
const assert = std.debug.assert;

const Math = @import("platform").math;
const Rendering = @import("../rendering/rendering.zig");

const Scaling = @import("Scaling.zig");
const layout = @import("layout.zig");
const TextureAtlas = @import("TextureAtlas.zig").TextureAtlas;

pub const Anchor = layout.Anchor;
pub const Color = @import("Color.zig").Color;
pub const Vertex = Rendering.Vertex;
pub const BatchMesh = Rendering.MeshType(Vertex);
pub const BatchMeshData = Rendering.MeshDataType(Vertex);
pub const TextMesh = struct {
    data: BatchMeshData,
    mesh: BatchMesh,

    pub fn deinit(self: *TextMesh, allocator: std.mem.Allocator) void {
        defer self.* = undefined;

        self.mesh.deinit();
        self.data.deinit(allocator);
    }

    pub fn draw(self: *TextMesh, model: *const Math.Mat4) void {
        self.mesh.draw(model);
    }
};

const FontBatcher = @This();

const glyph_cols: u32 = 16;
const glyph_rows: u32 = 16;
const glyph_count: u32 = 256;
const glyph_size: u32 = 8;
const space_width: u8 = 4;
const default_spacing: i8 = 1;
const max_entries: u16 = 1024;
const max_text_bytes: u16 = 8192;
/// Optional application-owned inline styling. A control consumes no glyph width.
/// Return null for literal text; lengths outside 1..text.len are ignored.
pub const StyleControl = struct {
    length: usize,
    color: ?Color = null,
    shadow_color: ?Color = null,
};
pub const StyleParser = *const fn (text: []const u8) ?StyleControl;

pub const TextEntry = struct {
    str: []const u8,
    color: Color,
    shadow_color: Color,
    pos_x: i16,
    pos_y: i16,
    spacing: i8,
    layer: u8,
    scale: u8 = 1,
    reference: Anchor,
    origin: Anchor,
    /// Clips individual glyphs and shadows, including their UVs.
    clip: ?layout.LogicalRect = null,
};

glyph_widths: [glyph_count]u8,
atlas: TextureAtlas,
texture: *const Rendering.Texture,
entries: [2][max_entries]TextEntry,
text_bufs: [2][max_text_bytes]u8,
text_used: [2]u16,
count: u16,
prev_count: u16,
current: u1,
last_screen_w: u32,
last_screen_h: u32,
mesh_data: BatchMeshData,
mesh: BatchMesh,
allocator: std.mem.Allocator,
/// Null renders every byte literally. Set before measurement and rendering.
style_parser: ?StyleParser = null,

pub fn init(allocator: std.mem.Allocator, texture: *const Rendering.Texture) !FontBatcher {
    assert(texture.width == 128);
    assert(texture.height == 128);
    var mesh_data = try BatchMeshData.init(allocator);
    errdefer mesh_data.deinit(allocator);
    return .{
        .glyph_widths = compute_glyph_widths(texture),
        .atlas = TextureAtlas.init(128, 128, glyph_rows, glyph_cols),
        .texture = texture,
        .entries = undefined,
        .text_bufs = undefined,
        .text_used = .{ 0, 0 },
        .count = 0,
        .prev_count = 0,
        .current = 0,
        .last_screen_w = 0,
        .last_screen_h = 0,
        .mesh_data = mesh_data,
        .mesh = try BatchMesh.init(&.{}),
        .allocator = allocator,
    };
}

pub fn deinit(self: *FontBatcher) void {
    defer self.* = undefined;

    self.mesh.deinit();
    self.mesh_data.deinit(self.allocator);
}

/// Recomputes glyph widths and geometry after the font texture changes.
pub fn refresh(self: *FontBatcher) void {
    self.glyph_widths = compute_glyph_widths(self.texture);
    self.prev_count = 0;
    self.last_screen_w = 0;
    self.last_screen_h = 0;
}

pub fn clear(self: *FontBatcher) void {
    self.prev_count = self.count;
    self.current ^= 1;
    self.count = 0;
    self.text_used[self.current] = 0;
}

/// Force the next flush to rebuild the mesh regardless of entry equality.
pub fn mark_dirty(self: *FontBatcher) void {
    self.prev_count = 0;
}

pub fn add_text(self: *FontBatcher, entry: *const TextEntry) void {
    assert(self.count < max_entries);
    assert(entry.str.len > 0);
    assert(entry.str.len <= max_text_bytes - self.text_used[self.current]);

    if (self.count >= max_entries) return;
    if (entry.str.len > max_text_bytes) return;
    const len: u16 = @intCast(entry.str.len);
    if (len > max_text_bytes - self.text_used[self.current]) return;

    const start = self.text_used[self.current];
    const end = start + len;
    const dst = self.text_bufs[self.current][start..end];
    @memcpy(dst, entry.str);

    self.entries[self.current][self.count] = entry.*;
    self.entries[self.current][self.count].str = dst;
    self.count += 1;
    self.text_used[self.current] = end;
}

pub fn update(self: *FontBatcher) !void {
    if (self.count == 0) return;

    const size = Rendering.surface_size();
    const screen_w = size.width;
    const screen_h = size.height;

    const curr = self.entries[self.current][0..self.count];
    const prev = self.entries[self.current ^ 1][0..self.prev_count];
    const changed = !entries_equal(curr, prev);
    const resized = screen_w != self.last_screen_w or screen_h != self.last_screen_h;

    if (changed or resized) {
        try self.rebuild(screen_w, screen_h);
        self.last_screen_w = screen_w;
        self.last_screen_h = screen_h;
    }
}

pub fn draw(self: *FontBatcher) void {
    if (self.count == 0) return;

    Rendering.set_state(&.{ .texture = self.texture.handle });
    self.mesh.draw(&Math.Mat4.identity());
}

pub fn flush(self: *FontBatcher) !void {
    try self.update();
    self.draw();
}

/// Changes the application parser and invalidates cached geometry.
pub fn set_style_parser(self: *FontBatcher, parser: ?StyleParser) void {
    self.style_parser = parser;
    self.mark_dirty();
}
fn parse_style(self: *const FontBatcher, text: []const u8) ?StyleControl {
    const parser = self.style_parser orelse return null;
    const control = parser(text) orelse return null;
    return if (control.length > 0 and control.length <= text.len) control else null;
}

/// Measures logical pixels, including spacing and scale. Application styling
/// controls, when configured, occupy no glyph width.
pub fn string_width(self: *const FontBatcher, str: []const u8, spacing: i8, text_scale: u8) i16 {
    if (str.len == 0) return 0;
    assert(text_scale > 0);
    const s: i32 = text_scale;
    var total: i32 = 0;
    var visible: u32 = 0;
    var i: usize = 0;
    while (i < str.len) {
        if (self.parse_style(str[i..])) |control| {
            i += control.length;
            continue;
        }
        total += @as(i32, self.glyph_widths[str[i]]) * s;
        visible += 1;
        i += 1;
    }
    if (visible == 0) return 0;
    const gaps: i32 = @intCast(visible - 1);
    total += gaps * (@as(i32, default_spacing) + @as(i32, spacing)) * s;
    return @intCast(@min(total, std.math.maxInt(i16)));
}

/// Returns the longest prefix fitting `max_w`, in bytes, without splitting application styling controls.
pub fn fit_width(self: *const FontBatcher, str: []const u8, max_w: i16, spacing: i8, text_scale: u8) usize {
    if (max_w <= 0 or str.len == 0) return 0;
    assert(text_scale > 0);
    const s: i32 = text_scale;
    const advance: i32 = (@as(i32, default_spacing) + @as(i32, spacing)) * s;
    var total: i32 = 0;
    var visible: u32 = 0;
    var i: usize = 0;
    var last_fit: usize = 0;
    while (i < str.len) {
        if (self.parse_style(str[i..])) |control| {
            i += control.length;
            last_fit = i;
            continue;
        }
        const gw: i32 = @as(i32, self.glyph_widths[str[i]]) * s;
        const gap: i32 = if (visible > 0) advance else 0;
        if (total + gap + gw > @as(i32, max_w)) break;
        total += gap + gw;
        visible += 1;
        i += 1;
        last_fit = i;
    }
    return last_fit;
}

/// Creates a standalone mesh for a rendered string in normalized [-1,1] space.
/// The caller must release the result with `TextMesh.deinit(allocator)`.
/// Draw with `mesh.draw(&model_matrix)` after binding the font texture.
pub fn build_mesh(
    self: *const FontBatcher,
    str: []const u8,
    color: Color,
    shadow_color: Color,
    spacing: i8,
    text_scale: u8,
) !TextMesh {
    assert(str.len > 0);
    assert(text_scale > 0);
    var data = try BatchMeshData.init(self.allocator);
    errdefer data.deinit(self.allocator);
    var mesh = try BatchMesh.init(&.{});
    errdefer mesh.deinit();

    const has_shadow = shadow_color.a > 0;
    const n_chars: u32 = @intCast(str.len);
    const mult: u32 = if (has_shadow) 2 else 1;
    try data.ensure_quad_capacity(
        self.allocator,
        @as(usize, n_chars * mult),
    );

    const s: i32 = text_scale;
    const text_w: i32 = self.string_width(str, spacing, text_scale);
    const text_h: i32 = @as(i32, glyph_size) * s;

    // Extend extent to include shadow so all vertices stay within [-1,1].
    const pad: i32 = if (has_shadow) s else 0;
    const ext_w = text_w + pad;
    const ext_h = text_h + pad;

    if (has_shadow) {
        emit_string_local(self, &data, str, spacing, s, s, 32766, shadow_color, true, ext_w, ext_h, text_scale);
    }
    emit_string_local(self, &data, str, spacing, 0, 0, 32765, color, false, ext_w, ext_h, text_scale);

    mesh.update(&data);
    return .{ .data = data, .mesh = mesh };
}

/// Positions exported text in logical pixels, rotating before conversion to NDC.
pub fn mesh_matrix(
    self: *const FontBatcher,
    str: []const u8,
    spacing: i8,
    text_scale: u8,
    pos_x: i16,
    pos_y: i16,
    reference: Anchor,
    origin: Anchor,
    rot_z: f32,
    extra_scale: f32,
    layer: u8,
) Math.Mat4 {
    const size = Rendering.surface_size();
    const screen_w = size.width;
    const screen_h = size.height;
    const ui_scale = Scaling.compute(screen_w, screen_h);
    const sw: f32 = @floatFromInt(screen_w);
    const sh: f32 = @floatFromInt(screen_h);
    const us: f32 = @floatFromInt(ui_scale);

    const ts: i16 = text_scale;
    const tw_i = self.string_width(str, spacing, text_scale);
    const th_i: i16 = @as(i16, glyph_size) * ts;
    const max_lx: i16 = @intCast(layout.logical_width(screen_w, ui_scale));
    const max_ly: i16 = @intCast(layout.logical_height(screen_h, ui_scale));

    const ref = anchor_point(reference, max_lx, max_ly);
    const orig = anchor_point(origin, tw_i, th_i);
    const tw: f32 = @floatFromInt(tw_i);
    const th: f32 = @floatFromInt(th_i);
    const tl_x: i16 = ref.x + pos_x - orig.x;
    const tl_y: i16 = ref.y + pos_y - orig.y;
    const cx: f32 = @as(f32, @floatFromInt(tl_x)) + tw / 2.0;
    const cy: f32 = @as(f32, @floatFromInt(tl_y)) + th / 2.0;

    const s_pixel = Math.Mat4.scaling(tw / 2.0, th / 2.0, 1);
    const r = Math.Mat4.rotation_z(std.math.degreesToRadians(rot_z));
    const s_ndc = Math.Mat4.scaling(2.0 * us * extra_scale / sw, 2.0 * us * extra_scale / sh, 1);
    // Exported vertices start at layer 0 (SNORM z = 32765..32766).
    const z: f32 = -@as(f32, @floatFromInt(layer)) * 2.0 / 32767.0;
    const t = Math.Mat4.translation(2.0 * cx * us / sw - 1.0, 1.0 - 2.0 * cy * us / sh, z);
    return s_pixel.mul(r).mul(s_ndc).mul(t);
}

fn entries_equal(a: []const TextEntry, b: []const TextEntry) bool {
    if (a.len != b.len) return false;
    for (a, b) |*x, *y| {
        // Slice headers cannot detect in-place text edits.
        if (!std.mem.eql(u8, x.str, y.str)) return false;
        if (!std.meta.eql(x.color, y.color)) return false;
        if (!std.meta.eql(x.shadow_color, y.shadow_color)) return false;
        if (x.pos_x != y.pos_x) return false;
        if (x.pos_y != y.pos_y) return false;
        if (x.spacing != y.spacing) return false;
        if (x.layer != y.layer) return false;
        if (x.scale != y.scale) return false;
        if (x.reference != y.reference) return false;
        if (x.origin != y.origin) return false;
        if (!std.meta.eql(x.clip, y.clip)) return false;
    }
    return true;
}

fn rebuild(self: *FontBatcher, screen_w: u32, screen_h: u32) !void {
    const scale = Scaling.compute(screen_w, screen_h);
    const entries = self.entries[self.current][0..self.count];

    var total_quads: u32 = 0;
    for (entries) |*e| {
        const mult: u32 = if (e.shadow_color.a > 0) 2 else 1;
        total_quads += @as(u32, @intCast(e.str.len)) * mult;
    }

    self.mesh_data.clear_retaining_capacity();
    try self.mesh_data.ensure_quad_capacity(self.allocator, @as(usize, total_quads));

    for (entries) |*e| {
        append_geometry(self, &self.mesh_data, e, screen_w, screen_h, scale);
    }
    self.mesh.update(&self.mesh_data);
}

pub fn append_geometry(
    self: *const FontBatcher,
    mesh: *BatchMeshData,
    entry: *const TextEntry,
    screen_w: u32,
    screen_h: u32,
    ui_scale: u32,
) void {
    assert(entry.scale > 0);
    const str = entry.str;
    const ts: i16 = entry.scale;
    const text_w = self.string_width(str, entry.spacing, entry.scale);
    const text_h: i16 = @as(i16, glyph_size) * ts;

    const max_lx: i16 = @intCast(layout.logical_width(screen_w, ui_scale));
    const max_ly: i16 = @intCast(layout.logical_height(screen_h, ui_scale));

    const ref = anchor_point(entry.reference, max_lx, max_ly);
    const orig = anchor_point(entry.origin, text_w, text_h);
    const base_x: i32 = @as(i32, ref.x) + entry.pos_x - orig.x;
    const base_y: i32 = @as(i32, ref.y) + entry.pos_y - orig.y;

    // Two z-levels per layer: shadow behind, text in front.
    const shadow_z: i16 = 32766 - @as(i16, entry.layer) * 2;
    const text_z: i16 = shadow_z - 1;

    if (entry.shadow_color.a > 0) {
        emit_string_screen(self, mesh, str, entry.spacing, @as(i32, base_x) + ts, @as(i32, base_y) + ts, shadow_z, entry.shadow_color, true, screen_w, screen_h, ui_scale, entry.scale, entry.clip);
    }
    emit_string_screen(self, mesh, str, entry.spacing, @as(i32, base_x), @as(i32, base_y), text_z, entry.color, false, screen_w, screen_h, ui_scale, entry.scale, entry.clip);
}

fn emit_string_screen(
    self: *const FontBatcher,
    mesh: *BatchMeshData,
    str: []const u8,
    spacing: i8,
    start_x: i32,
    start_y: i32,
    z: i16,
    base_color: Color,
    is_shadow: bool,
    screen_w: u32,
    screen_h: u32,
    ui_scale: u32,
    text_scale: u8,
    clip: ?layout.LogicalRect,
) void {
    const bounds = layout.intersection(.{ .x0 = 0, .y0 = 0, .x1 = @intCast(layout.logical_width(screen_w, ui_scale)), .y1 = @intCast(layout.logical_height(screen_h, ui_scale)) }, clip);
    const ts: i32 = text_scale;

    const y0: i16 = @intCast(@min(@max(start_y, bounds.y0), bounds.y1));
    const y1: i16 = @intCast(@max(bounds.y0, @min(start_y + @as(i32, glyph_size) * ts, bounds.y1)));
    if (y0 >= y1) return;
    const sy0 = logical_to_snorm_y(y0, screen_h, ui_scale);
    const sy1 = logical_to_snorm_y(y1, screen_h, ui_scale);
    const advance: i32 = (@as(i32, default_spacing) + @as(i32, spacing)) * ts;
    var cursor: i32 = start_x;
    var color: u32 = @bitCast(base_color);

    var i: usize = 0;
    while (i < str.len) {
        if (self.parse_style(str[i..])) |control| {
            if (if (is_shadow) control.shadow_color else control.color) |replacement| color = @bitCast(replacement);
            i += control.length;
            continue;
        }
        if (cursor >= bounds.x1 and advance >= 0) break;
        const byte = str[i];
        i += 1;
        const gw = self.glyph_widths[byte];
        if (gw == 0) {
            cursor += advance;
            continue;
        }
        const scaled_w: i32 = @as(i32, gw) * ts;
        const x0: i16 = @intCast(@min(bounds.x1, @max(cursor, bounds.x0)));
        const x1: i16 = @intCast(@max(bounds.x0, @min(cursor + scaled_w, bounds.x1)));
        if (x0 < x1) {
            const base = glyph_uvs(self, byte, gw);
            const uv_span: i32 = @as(i32, base[2]) - @as(i32, base[0]);
            const vis_l: i32 = @as(i32, x0) - cursor;
            const vis_r: i32 = @as(i32, x1) - cursor;
            const uv_l: i16 = @intCast(@as(i32, base[0]) + @divTrunc(uv_span * vis_l, scaled_w));
            const uv_r: i16 = @intCast(@as(i32, base[0]) + @divTrunc(uv_span * vis_r, scaled_w));
            const uv_h: i32 = @as(i32, base[3]) - base[1];
            const uv_t: i16 = @intCast(@as(i32, base[1]) + @divTrunc(uv_h * (@as(i32, y0) - start_y), @as(i32, glyph_size) * ts));
            const uv_b: i16 = @intCast(@as(i32, base[1]) + @divTrunc(uv_h * (@as(i32, y1) - start_y), @as(i32, glyph_size) * ts));
            emit_quad(mesh, logical_to_snorm_x(x0, screen_w, ui_scale), sy0, logical_to_snorm_x(x1, screen_w, ui_scale), sy1, z, uv_l, uv_t, uv_r, uv_b, color);
        }
        cursor += scaled_w + advance;
    }
}

fn emit_string_local(
    self: *const FontBatcher,
    mesh: *BatchMeshData,
    str: []const u8,
    spacing: i8,
    offset_x: i32,
    offset_y: i32,
    z: i16,
    base_color: Color,
    is_shadow: bool,
    extent_w: i32,
    extent_h: i32,
    text_scale: u8,
) void {
    const ts: i32 = text_scale;
    const advance: i32 = (@as(i32, default_spacing) + @as(i32, spacing)) * ts;
    const sy0 = local_to_snorm_y(offset_y, extent_h);
    const sy1 = local_to_snorm_y(offset_y + @as(i32, glyph_size) * ts, extent_h);
    var cursor: i32 = offset_x;
    var color: u32 = @bitCast(base_color);

    var i: usize = 0;
    while (i < str.len) {
        if (self.parse_style(str[i..])) |control| {
            if (if (is_shadow) control.shadow_color else control.color) |replacement| color = @bitCast(replacement);
            i += control.length;
            continue;
        }
        const byte = str[i];
        i += 1;
        const gw = self.glyph_widths[byte];
        if (gw == 0) {
            cursor += advance;
            continue;
        }
        const scaled_w: i32 = @as(i32, gw) * ts;
        const base = glyph_uvs(self, byte, gw);
        const sx0 = local_to_snorm_x(cursor, extent_w);
        const sx1 = local_to_snorm_x(cursor + scaled_w, extent_w);
        emit_quad(mesh, sx0, sy0, sx1, sy1, z, base[0], base[1], base[2], base[3], color);
        cursor += scaled_w + advance;
    }
}

fn glyph_uvs(self: *const FontBatcher, byte: u8, gw: u8) [4]i16 {
    const gx: u32 = @as(u32, byte) % glyph_cols;
    const gy: u32 = @as(u32, byte) / glyph_cols;
    const stride_u: i32 = @as(i32, 32767) >> self.atlas.col_log2;
    const stride_v: i32 = @as(i32, 32767) >> self.atlas.row_log2;
    const base_u: i32 = @as(i32, @intCast(gx)) * stride_u;
    const base_v: i32 = @as(i32, @intCast(gy)) * stride_v;
    return .{
        @intCast(base_u),
        @intCast(base_v),
        @intCast(base_u + @divTrunc(stride_u * @as(i32, gw), glyph_size)),
        @intCast(base_v + stride_v),
    };
}

fn emit_quad(
    mesh: *BatchMeshData,
    sx0: i16,
    sy0: i16,
    sx1: i16,
    sy1: i16,
    z: i16,
    uv_l: i16,
    uv_t: i16,
    uv_r: i16,
    uv_b: i16,
    color: u32,
) void {
    mesh.add_quad_assume_capacity(
        .{ .pos = .{ sx0, sy0, z }, .uv = .{ uv_l, uv_t }, .color = color },
        .{ .pos = .{ sx0, sy1, z }, .uv = .{ uv_l, uv_b }, .color = color },
        .{ .pos = .{ sx1, sy1, z }, .uv = .{ uv_r, uv_b }, .color = color },
        .{ .pos = .{ sx1, sy0, z }, .uv = .{ uv_r, uv_t }, .color = color },
    );
}

fn compute_glyph_widths(texture: *const Rendering.Texture) [glyph_count]u8 {
    assert(texture.width == 128);
    assert(texture.height == 128);

    var widths: [glyph_count]u8 = [1]u8{0} ** glyph_count;

    var code: u32 = 0;
    while (code < glyph_count) : (code += 1) {
        if (code == 0x20) {
            widths[code] = space_width;
            continue;
        }
        const gx = code % glyph_cols;
        const gy = code / glyph_cols;
        const bx = gx * glyph_size;
        const by = gy * glyph_size;

        var max_col: u8 = 0;
        var col: u32 = glyph_size;
        while (col > 0) {
            col -= 1;
            var row: u32 = 0;
            while (row < glyph_size) : (row += 1) {
                const rgba = texture.get_pixel(bx + col, by + row) catch .{ 0, 0, 0, 0 };
                if (rgba[3] > 0) {
                    max_col = @intCast(col + 1);
                    break;
                }
            }
            if (max_col > 0) break;
        }
        widths[code] = max_col;
    }
    return widths;
}

const anchor_point = layout.anchor_point;
const logical_to_snorm_x = layout.logical_to_snorm_x;
const logical_to_snorm_y = layout.logical_to_snorm_y;

/// Maps [0, extent] to [-32767, 32767] for normalized mesh export.
fn local_to_snorm_x(x: i32, extent_w: i32) i16 {
    return @intCast(@divTrunc((2 * x - extent_w) * 32767, extent_w));
}

/// Maps [0, extent] to [32767, -32767] (Y-flipped for top-left origin).
fn local_to_snorm_y(y: i32, extent_h: i32) i16 {
    return @intCast(@divTrunc((extent_h - 2 * y) * 32767, extent_h));
}

test "glyph clips trim horizontal and vertical texture coordinates" {
    var font: FontBatcher = undefined;
    font.style_parser = null;
    font.glyph_widths = @splat(8);
    font.atlas = TextureAtlas.init_grid(16, 16);
    var data = try BatchMeshData.init(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    try data.ensure_quad_capacity(std.testing.allocator, 2);
    font.append_geometry(&data, &.{ .str = "A", .color = Color.rgba(255, 255, 255, 255), .shadow_color = Color.rgba(0, 0, 0, 0), .pos_x = 50, .pos_y = 50, .spacing = 0, .layer = 0, .reference = .top_left, .origin = .middle_center, .clip = .{ .x0 = 48, .y0 = 48, .x1 = 52, .y1 = 52 } }, 100, 100, 1);
    const vertices = data.vertices.items;
    try std.testing.expect(vertices.len >= 4);
    const base = glyph_uvs(&font, 'A', 8);
    try std.testing.expectEqual(@as(i16, base[0] + 511), vertices[0].uv[0]);
    try std.testing.expectEqual(@as(i16, base[1] + 511), vertices[0].uv[1]);
    try std.testing.expectEqual(@as(i16, base[3] - 512), vertices[1].uv[1]);
}

test "font measurement fitting and geometry treat ampersands literally by default" {
    var font: FontBatcher = undefined;
    font.style_parser = null;
    font.glyph_widths = @splat(4);
    font.atlas = TextureAtlas.init_grid(16, 16);
    try std.testing.expectEqual(19, font.string_width("A&cB", 0, 1));
    try std.testing.expectEqual(2, font.fit_width("A&cB", 9, 0, 1));
    var data = try BatchMeshData.init(std.testing.allocator);
    defer data.deinit(std.testing.allocator);

    try data.ensure_quad_capacity(std.testing.allocator, 4);
    const color = Color.rgba(18, 52, 86, 255);
    font.append_geometry(&data, &.{ .str = "A&cB", .color = color, .shadow_color = Color.rgba(0, 0, 0, 0), .pos_x = 0, .pos_y = 0, .spacing = 0, .layer = 0, .reference = .top_left, .origin = .top_left }, 100, 100, 1);
    try std.testing.expectEqual(@as(usize, 4 * (if (Rendering.mesh.indexing_enabled) @as(usize, 4) else 6)), data.vertices.items.len);
    for (data.vertices.items) |vertex| try std.testing.expectEqual(@as(u32, @bitCast(color)), vertex.color);
}

test "invalid application styling lengths remain literal and never stall" {
    const Invalid = struct {
        fn parse(text: []const u8) ?StyleControl {
            return .{ .length = if (text[0] == '!') 0 else text.len + 1 };
        }
    };
    var font: FontBatcher = undefined;
    font.glyph_widths = @splat(1);
    font.style_parser = Invalid.parse;
    try std.testing.expectEqual(3, font.string_width("!?", 0, 1));
    try std.testing.expectEqual(1, font.fit_width("!?", 1, 0, 1));
}
