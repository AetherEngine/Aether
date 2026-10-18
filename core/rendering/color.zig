const std = @import("std");
const assert = std.debug.assert;
const math = @import("platform").math;

pub const Color = struct {
    pub const white: Color = .rgb(1, 1, 1);
    pub const black: Color = .rgb(0, 0, 0);

    components: @Vector(4, f32),

    pub fn rgb(r: f32, g: f32, b: f32) Color {
        return .rgba(r, g, b, 1);
    }

    pub fn rgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .components = .{ r, g, b, a } };
    }

    pub fn eql(a: Color, b: Color) bool {
        return @reduce(.And, a.components == b.components);
    }

    pub fn mul(a: Color, b: Color) Color {
        return .{ .components = a.components * b.components };
    }

    pub fn mix(a: Color, b: Color, t: f32) Color {
        return .{ .components = a.components + (b.components - a.components) * @as(@Vector(4, f32), @splat(t)) };
    }

    /// Every channel limited to [0, 1], ready for `to_render`.
    pub fn clamp(color: Color) Color {
        return .{ .components = math.clamp(color.components, @as(@Vector(4, f32), @splat(0)), @as(@Vector(4, f32), @splat(1))) };
    }

    /// Packed RGBA8 in the vertex colour layout, same bytes as `Ui.Color`.
    /// Channels must already be in [0, 1]; `clamp` first if unsure.
    pub fn to_render(color: Color) u32 {
        const one: @Vector(4, f32) = @splat(1.0);
        const zero: @Vector(4, f32) = @splat(0.0);
        assert(@reduce(.And, color.components >= zero) and @reduce(.And, color.components <= one));

        const max: @Vector(4, f32) = @splat(std.math.maxInt(u8));
        const bytes: @Vector(4, u8) = @intFromFloat(color.components * max);
        return @bitCast(bytes);
    }
};
