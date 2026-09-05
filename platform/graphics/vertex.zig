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
