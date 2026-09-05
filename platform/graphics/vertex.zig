const options = @import("options");

const StandardVertex = extern struct {
    pos: [3]i16,
    _pad: i16 = 0,
    color: u32,
    uv: [2]i16,
};

/// PSP GE requires UV, color, position order; other backends use layout offsets.
pub const PspVertex = extern struct {
    uv: [2]i16,
    color: u32,
    pos: [3]i16,
    _pad: i16 = 0,
};

pub const Vertex = if (options.config.platform == .psp) PspVertex else StandardVertex;

comptime {
    if (@sizeOf(Vertex) != 16) @compileError("Graphics.Vertex must stay 16 bytes");
    if (options.config.platform == .psp) {
        if (@offsetOf(Vertex, "uv") != 0) @compileError("PSP vertex uv must stay at byte offset 0");
        if (@offsetOf(Vertex, "color") != 4) @compileError("PSP vertex color must stay at byte offset 4");
        if (@offsetOf(Vertex, "pos") != 8) @compileError("PSP vertex pos must stay at byte offset 8");
    } else {
        if (@offsetOf(Vertex, "pos") != 0) @compileError("Graphics.Vertex.pos must stay at byte offset 0");
        if (@offsetOf(Vertex, "color") != 8) @compileError("Graphics.Vertex.color must stay at byte offset 8");
        if (@offsetOf(Vertex, "uv") != 12) @compileError("Graphics.Vertex.uv must stay at byte offset 12");
    }
}

pub const AttributeUsage = enum {
    position,
    uv,
    color,
    normal,
};

pub const AttributeFormat = enum(u8) {
    f32x2,
    f32x3,
    unorm8x2,
    unorm8x4,
    unorm16x2,
    unorm16x3,
    snorm16x2,
    snorm16x3,

    fn infer(comptime T: type) AttributeFormat {
        return switch (T) {
            [2]f32 => .f32x2,
            [3]f32 => .f32x3,
            [2]u8 => .unorm8x2,
            [4]u8, u32 => .unorm8x4,
            [2]u16 => .unorm16x2,
            [3]u16 => .unorm16x3,
            [2]i16 => .snorm16x2,
            [3]i16 => .snorm16x3,
            else => @compileError("Unsupported vertex attribute field type: " ++ @typeName(T)),
        };
    }

    pub fn count(self: AttributeFormat) usize {
        return switch (self) {
            .f32x2, .unorm8x2, .unorm16x2, .snorm16x2 => 2,
            .f32x3, .unorm16x3, .snorm16x3 => 3,
            .unorm8x4 => 4,
        };
    }
};

pub const Attribute = struct {
    location: u8,
    binding: u8 = 0,
    offset: usize,
    size: usize,
    format: AttributeFormat,
    usage: AttributeUsage,
};

pub const VertexLayout = struct {
    stride: usize,
    attributes: []const Attribute,
};

pub const Attributes = [3]Attribute{
    make_attribute(Vertex, "pos", 0, .position, 3),
    make_attribute(Vertex, "color", 1, .color, 4),
    make_attribute(Vertex, "uv", 2, .uv, 2),
};
pub const Layout = VertexLayout{
    .stride = @sizeOf(Vertex),
    .attributes = &Attributes,
};

fn make_attribute(
    comptime V: type,
    comptime field_name: []const u8,
    comptime location: u8,
    comptime usage: AttributeUsage,
    comptime expected_count: usize,
) Attribute {
    if (!@hasField(V, field_name)) {
        @compileError("Graphics.Vertex is missing required field '" ++ field_name ++ "'");
    }

    const format = AttributeFormat.infer(@FieldType(V, field_name));
    if (format.count() != expected_count) {
        @compileError("Graphics.Vertex field '" ++ field_name ++ "' has the wrong component count");
    }

    return .{
        .location = location,
        .offset = @offsetOf(V, field_name),
        .size = format.count(),
        .format = format,
        .usage = usage,
    };
}

/// Most backends normalize signed positions by 32767; PSP GE divides by
/// 32768. Select this explicitly when generating data for a different consumer.
pub const PositionNormalization = enum {
    snorm16,
    psp_ge,

    pub fn divisor(self: PositionNormalization) f32 {
        return if (self == .snorm16) 32767 else 32768;
    }
};
pub const native_position_normalization: PositionNormalization = if (options.config.platform == .psp) .psp_ge else .snorm16;

/// Quantizes origin-relative world coordinates into the existing 16-byte
/// Vertex layout. The model matrix restores world units using model_scale().
/// No saturation occurs: a quad that exceeds the range can be culled by its
/// caller. snorm16 excludes -32768 to avoid its asymmetric clamped endpoint.
pub const PositionEncoding = struct {
    const std = @import("std");
    const Vec3 = @import("../math/vec3.zig");
    pub const Error = error{ InvalidScale, PositionOutOfRange };

    units_per_world_unit: f32,
    normalization: PositionNormalization,

    pub fn init(units_per_world_unit: f32, normalization: PositionNormalization) Error!PositionEncoding {
        if (!std.math.isFinite(units_per_world_unit) or units_per_world_unit <= 0 or
            !std.math.isFinite(normalization.divisor() / units_per_world_unit)) return error.InvalidScale;
        return .{ .units_per_world_unit = units_per_world_unit, .normalization = normalization };
    }

    pub fn model_scale(self: PositionEncoding) f32 {
        return self.normalization.divisor() / self.units_per_world_unit;
    }

    pub fn encode_component(self: PositionEncoding, value: f32) Error!i16 {
        const scaled = @round(value * self.units_per_world_unit);
        const minimum: f32 = if (self.normalization == .snorm16) -32767 else -32768;
        if (!std.math.isFinite(scaled) or scaled < minimum or scaled > 32767) return error.PositionOutOfRange;
        return @intFromFloat(scaled);
    }

    pub fn encode(self: PositionEncoding, value: Vec3) Error![3]i16 {
        return .{ try self.encode_component(value.x), try self.encode_component(value.y), try self.encode_component(value.z) };
    }

    pub fn decode(self: PositionEncoding, value: [3]i16) Vec3 {
        return Vec3.new(@as(f32, @floatFromInt(value[0])) / self.units_per_world_unit, @as(f32, @floatFromInt(value[1])) / self.units_per_world_unit, @as(f32, @floatFromInt(value[2])) / self.units_per_world_unit);
    }
};

test "compact position ranges rounding and native model scale are explicit" {
    const std = @import("std");
    const encoding = try PositionEncoding.init(128, .snorm16);
    try std.testing.expectEqual(@as(i16, 128), try encoding.encode_component(1));
    try std.testing.expectEqual(@as(i16, -129), try encoding.encode_component(-1.004));
    try std.testing.expectError(error.PositionOutOfRange, encoding.encode_component(256));
    try std.testing.expectError(error.PositionOutOfRange, encoding.encode_component(-256));
    const psp = try PositionEncoding.init(128, .psp_ge);
    try std.testing.expectEqual(@as(i16, -32768), try psp.encode_component(-256));
    try std.testing.expectEqual(@as(f32, 256), psp.model_scale());
    try std.testing.expectApproxEqAbs(@as(f32, 1), @as(f32, 128) / 32767 * encoding.model_scale(), 0.00001);
    try std.testing.expectError(error.PositionOutOfRange, encoding.encode_component(std.math.nan(f32)));
    try std.testing.expectError(error.InvalidScale, PositionEncoding.init(0, .snorm16));
}
