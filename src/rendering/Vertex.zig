const options = @import("options");

pub const Vertex = if (options.config.platform == .nintendo_3ds) Vertex3DS else VertexBaseline;

const Vertex3DS = extern struct {
    pos: [3]i16,
    uv: [2]i16,
    color: u32 align(2),
};

const VertexBaseline = extern struct {
    uv: [2]i16,
    color: u32,
    pos: [3]i16,
    _pad: i16 = 0,
};

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

pub const Attributes = attributesFromVertex(Vertex);
pub const Layout = VertexLayout{
    .stride = @sizeOf(Vertex),
    .attributes = &Attributes,
};

fn attributesFromVertex(comptime V: type) [3]Attribute {
    return .{
        makeAttribute(V, "pos", 0, .position, 3),
        makeAttribute(V, "color", 1, .color, 4),
        makeAttribute(V, "uv", 2, .uv, 2),
    };
}

fn makeAttribute(
    comptime V: type,
    comptime field_name: []const u8,
    comptime location: u8,
    comptime usage: AttributeUsage,
    comptime expected_count: usize,
) Attribute {
    if (!hasField(V, field_name)) {
        @compileError("Rendering.Vertex is missing required field '" ++ field_name ++ "'");
    }

    const format = AttributeFormat.infer(@FieldType(V, field_name));
    if (format.count() != expected_count) {
        @compileError("Rendering.Vertex field '" ++ field_name ++ "' has the wrong component count");
    }

    return .{
        .location = location,
        .offset = @offsetOf(V, field_name),
        .size = format.count(),
        .format = format,
        .usage = usage,
    };
}

fn hasField(comptime T: type, comptime field_name: []const u8) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;

    inline for (info.@"struct".fields) |field| {
        if (comptime eql(field.name, field_name)) return true;
    }
    return false;
}

fn eql(comptime a: []const u8, comptime b: []const u8) bool {
    if (a.len != b.len) return false;
    inline for (a, 0..) |ch, i| {
        if (ch != b[i]) return false;
    }
    return true;
}
