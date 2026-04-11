const Platform = @import("../platform/platform.zig");
const gfx = Platform.gfx;

pub const Handle = u32;

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
            else => @compileError("Unsupported attribute field type"),
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

pub const AttributeSpec = struct {
    field: []const u8,
    location: u8,
    binding: u8 = 0,
    usage: AttributeUsage,
};

pub fn attributes_from_struct(comptime V: type, comptime specs: []const AttributeSpec) [specs.len]Attribute {
    comptime var attrs: [specs.len]Attribute = undefined;

    inline for (specs, 0..) |s, i| {
        const format = AttributeFormat.infer(@FieldType(V, s.field));
        attrs[i] = .{
            .location = s.location,
            .binding = s.binding,
            .size = format.count(),
            .offset = @offsetOf(V, s.field),
            .format = format,
            .usage = s.usage,
        };
    }

    return attrs;
}

pub fn layout_from_struct(comptime V: type, comptime attrs: []const Attribute) VertexLayout {
    return .{ .stride = @sizeOf(V), .attributes = attrs };
}

handle: Handle,

pub fn new(layout: VertexLayout, vs: ?[:0]align(4) const u8, fs: ?[:0]align(4) const u8) !Handle {
    return gfx.api.create_pipeline(layout, vs, fs);
}

pub fn deinit(handle: Handle) void {
    gfx.api.destroy_pipeline(handle);
}

pub fn bind(handle: Handle) void {
    gfx.api.bind_pipeline(handle);
}
