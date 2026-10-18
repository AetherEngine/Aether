//! Scalar maths that stays out of library calls.

const std = @import("std");
const assert = std.debug.assert;

/// The smaller of `a` and `b`, for integers, floats, and vectors of either.
/// Where `@min` drops a NaN, this returns `a` unless `b` is smaller.
pub inline fn min(a: anytype, b: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    const x: T = a;
    const y: T = b;
    return if (comptime is_vector(T)) @select(@typeInfo(T).vector.child, y < x, y, x) else if (y < x) y else x;
}

/// The larger of `a` and `b`, like `min`.
pub inline fn max(a: anytype, b: anytype) @TypeOf(a, b) {
    const T = @TypeOf(a, b);
    const x: T = a;
    const y: T = b;
    return if (comptime is_vector(T)) @select(@typeInfo(T).vector.child, y > x, y, x) else if (y > x) y else x;
}

/// `value` limited to `[lower, upper]`, like `std.math.clamp`. A NaN comes
/// out as `lower`.
pub inline fn clamp(value: anytype, lower: anytype, upper: anytype) @TypeOf(value, lower, upper) {
    const T = @TypeOf(value, lower, upper);
    const v: T = value;
    const lo: T = lower;
    const hi: T = upper;
    if (comptime is_vector(T)) {
        const C = @typeInfo(T).vector.child;
        return @select(C, v > hi, hi, @select(C, v > lo, v, lo));
    }
    assert(lo <= hi);
    return if (v > hi) hi else if (v > lo) v else lo;
}

fn is_vector(comptime T: type) bool {
    return @typeInfo(T) == .vector;
}

/// `x` rounded toward zero, like `@trunc`.
pub inline fn trunc(x: anytype) @TypeOf(x) {
    if (!has_fraction(x)) return x;
    return std.math.copysign(whole_part(x), x);
}

/// `x` rounded down, like `@floor`.
pub inline fn floor(x: anytype) @TypeOf(x) {
    if (!has_fraction(x)) return x;
    const whole = whole_part(x);
    return std.math.copysign(if (x < whole) whole - 1 else whole, x);
}

/// `x` rounded up, like `@ceil`.
pub inline fn ceil(x: anytype) @TypeOf(x) {
    if (!has_fraction(x)) return x;
    const whole = whole_part(x);
    return std.math.copysign(if (x > whole) whole + 1 else whole, x);
}

/// `x` rounded to the nearest whole number, halves away from zero, like
/// `@round`.
pub inline fn round(x: anytype) @TypeOf(x) {
    if (!has_fraction(x)) return x;
    const whole = whole_part(x);
    // Exact: it only clears the whole-number bits of `x`
    const fraction = x - whole;
    const rounded = if (fraction >= 0.5) whole + 1 else if (fraction <= -0.5) whole - 1 else whole;
    return std.math.copysign(rounded, x);
}

/// Whether `x` may have a fractional part. Past 2^mantissa every float is
/// whole, and NaN and the infinities compare false, so all of those are
/// returned as they are.
inline fn has_fraction(x: anytype) bool {
    const T = @TypeOf(x);
    comptime assert(T == f32 or T == f64);
    const limit: T = 1 << std.math.floatMantissaBits(T);
    return @abs(x) < limit;
}

/// `x` truncated through an integer of its width, which `has_fraction`
/// guarantees it fits. The conversions are native on every target.
inline fn whole_part(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    return @floatFromInt(@as(@Int(.signed, @bitSizeOf(T)), @intFromFloat(x)));
}

/// Sine. f32 is single precision throughout for |x| < 6000, and within 1e-6
/// of the true value up to about 1e9, past which it's still in [-1, 1]. f64
/// uses musl's kernels and is as accurate as them below about 1.6e6, after
/// which the reduction loses accuracy in proportion to |x|.
pub fn sin(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    if (T == f64) {
        const r = reduce64(x);
        return switch (r.quadrant) {
            0 => sin_kernel64(r.y, r.tail),
            1 => cos_kernel64(r.y, r.tail),
            2 => -sin_kernel64(r.y, r.tail),
            3 => -cos_kernel64(r.y, r.tail),
        };
    }
    comptime assert(T == f32);
    const r = reduce32(x);
    return switch (r.quadrant) {
        0 => sin_kernel32(r.y),
        1 => cos_kernel32(r.y),
        2 => -sin_kernel32(r.y),
        3 => -cos_kernel32(r.y),
    };
}

/// Cosine, like `sin`.
pub fn cos(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    if (T == f64) {
        const r = reduce64(x);
        return switch (r.quadrant) {
            0 => cos_kernel64(r.y, r.tail),
            1 => -sin_kernel64(r.y, r.tail),
            2 => -cos_kernel64(r.y, r.tail),
            3 => sin_kernel64(r.y, r.tail),
        };
    }
    comptime assert(T == f32);
    const r = reduce32(x);
    return switch (r.quadrant) {
        0 => cos_kernel32(r.y),
        1 => -sin_kernel32(r.y),
        2 => -cos_kernel32(r.y),
        3 => sin_kernel32(r.y),
    };
}

/// Tangent, as the ratio of the sine and cosine kernels, so a couple of ulps
/// off `sin(x) / cos(x)` worked exactly. Reduction is as in `sin`.
pub fn tan(x: anytype) @TypeOf(x) {
    const T = @TypeOf(x);
    if (T == f64) {
        const r = reduce64(x);
        const s = sin_kernel64(r.y, r.tail);
        const c = cos_kernel64(r.y, r.tail);
        return if (r.quadrant & 1 == 0) s / c else -c / s;
    }
    comptime assert(T == f32);
    const r = reduce32(x);
    const s = sin_kernel32(r.y);
    const c = cos_kernel32(r.y);
    return if (r.quadrant & 1 == 0) s / c else -c / s;
}

const Reduced32 = struct { y: f32, quadrant: u2 };

/// `x` as `y` plus a whole number of quarter turns, with |y| <= pi/4.
fn reduce32(x: f32) Reduced32 {
    // Past this, k times the split pi/2 below stops being exact. That's rare
    // for angles, so it goes the slow way.
    if (!(@abs(x) < 6000)) {
        const r = reduce64(x);
        return .{ .y = @floatCast(r.y), .quadrant = r.quadrant };
    }
    const two_over_pi: f32 = 0.636619772;
    // pi/2 in three parts, the first two of 12 bits, so k times either is
    // exact for k up to 4096
    const pio2_hi: f32 = 1.5703125;
    const pio2_mid: f32 = 4.837512969970703e-4;
    const pio2_lo: f32 = 7.549790126404332e-8;

    const k: i32 = @intFromFloat(x * two_over_pi + std.math.copysign(@as(f32, 0.5), x));
    const kf: f32 = @floatFromInt(k);
    return .{
        .y = ((x - kf * pio2_hi) - kf * pio2_mid) - kf * pio2_lo,
        .quadrant = @truncate(@as(u32, @bitCast(k))),
    };
}

// Minimax polynomials on [-pi/4, pi/4], from musl's __sindf and __cosdf

fn sin_kernel32(x: f32) f32 {
    const z = x * x;
    return x + x * z * (-0.166666666416 + z * (0.00833332938589 + z * (-0.000198393348361 + z * 0.00000271831149399)));
}

fn cos_kernel32(x: f32) f32 {
    const z = x * x;
    return 1 + z * (-0.499999997251 + z * (0.0416666233237 + z * (-0.00138867637746 + z * 0.0000243904487963)));
}

/// `y + tail` is `x` less a whole number of quarter turns.
const Reduced64 = struct { y: f64, tail: f64, quadrant: u2 };

/// musl's __rem_pio2 for |x| up to about 1.6e6. Larger arguments are first
/// brought into [0, 2pi) with `@mod` against a rounded 2pi rather than
/// musl's exact multi-precision reduction, which no game angle needs.
fn reduce64(x_in: f64) Reduced64 {
    if (!std.math.isFinite(x_in)) return .{ .y = x_in - x_in, .tail = 0, .quadrant = 0 };
    const x = if (@abs(x_in) < 0x1p20 * std.math.pi / 2.0) x_in else @mod(x_in, std.math.tau);

    const invpio2 = 6.36619772367581382433e-01;
    // pi/2 in 33-bit parts, each with the remainder after it
    const pio2_1 = 1.57079632673412561417e+00;
    const pio2_1t = 6.07710050650619224932e-11;
    const pio2_2 = 6.07710050630396597660e-11;
    const pio2_2t = 2.02226624879595063154e-21;
    const pio2_3 = 2.02226624871116645580e-21;
    const pio2_3t = 8.47842766036889956997e-32;
    const pio4 = std.math.pi / 4.0;
    const toint = 1.5 / std.math.floatEps(f64);

    // Round to nearest without `@round`
    var k = (x * invpio2 + toint) - toint;
    var r = x - k * pio2_1;
    var w = k * pio2_1t;
    // Matters with directed rounding
    if (r - w < -pio4) {
        k -= 1;
        r = x - k * pio2_1;
        w = k * pio2_1t;
    } else if (r - w > pio4) {
        k += 1;
        r = x - k * pio2_1;
        w = k * pio2_1t;
    }
    var y = r - w;
    const ex: i32 = exponent_bits(x);
    if (ex - exponent_bits(y) > 16) {
        // Cancellation: a second round, good to 118 bits
        var t = r;
        w = k * pio2_2;
        r = t - w;
        w = k * pio2_2t - ((t - r) - w);
        y = r - w;
        if (ex - exponent_bits(y) > 49) {
            // And a third, good to 151, which covers every case
            t = r;
            w = k * pio2_3;
            r = t - w;
            w = k * pio2_3t - ((t - r) - w);
            y = r - w;
        }
    }
    const n: i32 = @intFromFloat(k);
    return .{ .y = y, .tail = (r - y) - w, .quadrant = @truncate(@as(u32, @bitCast(n))) };
}

fn exponent_bits(x: f64) i32 {
    return @intCast((@as(u64, @bitCast(x)) >> 52) & 0x7ff);
}

// musl's __sin and __cos: minimax polynomials on [-pi/4, pi/4], taking the
// reduction's tail for the last bits

fn sin_kernel64(x: f64, tail: f64) f64 {
    const s1 = -1.66666666666666324348e-01;
    const s2 = 8.33333333332248946124e-03;
    const s3 = -1.98412698298579493134e-04;
    const s4 = 2.75573137070700676789e-06;
    const s5 = -2.50507602534068634195e-08;
    const s6 = 1.58969099521155010221e-10;

    const z = x * x;
    const w = z * z;
    const r = s2 + z * (s3 + z * s4) + z * w * (s5 + z * s6);
    const v = z * x;
    return x - ((z * (0.5 * tail - v * r) - tail) - v * s1);
}

fn cos_kernel64(x: f64, tail: f64) f64 {
    const c1 = 4.16666666666666019037e-02;
    const c2 = -1.38888888888741095749e-03;
    const c3 = 2.48015872894767294178e-05;
    const c4 = -2.75573143513906633035e-07;
    const c5 = 2.08757232129817482790e-09;
    const c6 = -1.13596475577881948265e-11;

    const z = x * x;
    const zs = z * z;
    const r = z * (c1 + z * (c2 + z * c3)) + zs * zs * (c4 + z * (c5 + z * c6));
    const hz = 0.5 * z;
    const w = 1.0 - hz;
    return w + (((1.0 - w) - hz) + (z * r - x * tail));
}

test "min, max and clamp match the builtins" {
    const reference = @import("builtin_reference.zig");
    const values = [_]f32{ -1e30, -2.5, -1, -0.25, 0, 0.25, 1, 2.5, 1e30, std.math.inf(f32) };
    for (values) |a| for (values) |b| {
        try std.testing.expectEqual(reference.min(a, b), min(a, b));
        try std.testing.expectEqual(reference.max(a, b), max(a, b));
        if (a <= b) for (values) |v| {
            try std.testing.expectEqual(reference.clamp(v, a, b), clamp(v, a, b));
        };
    };
    try std.testing.expectEqual(@as(u32, 3), min(@as(u32, 7), 3));
    try std.testing.expectEqual(@as(i8, -4), max(@as(i8, -4), -9));
    try std.testing.expectEqual(@as(f32, 0), clamp(std.math.nan(f32), 0, 1));

    const v: @Vector(4, f32) = .{ -1, 0.5, 2, 1 };
    const lo: @Vector(4, f32) = @splat(0);
    const hi: @Vector(4, f32) = @splat(1);
    try std.testing.expectEqual(@Vector(4, f32){ 0, 0.5, 1, 1 }, clamp(v, lo, hi));
    try std.testing.expectEqual(@Vector(4, f32){ -1, 0, 0, 0 }, min(v, lo));
}

test "rounding matches the builtins bit for bit" {
    const reference = @import("builtin_reference.zig");
    inline for (.{ f32, f64 }) |T| {
        const specials = [_]T{
            0,                    -0.0,                  0.5,                  -0.5,
            1.5,                  -1.5,                  2.5,                  0.49999997,
            -0.49999997,          0x1p23 - 0.5,          0x1p52 - 0.5,         0x1p23,
            0x1p53,               -0x1p60,               std.math.inf(T),      -std.math.inf(T),
            std.math.floatMin(T), -std.math.floatMin(T), std.math.floatMax(T),
        };
        for (specials) |x| try expect_rounding(T, reference, x);
        var x: T = -300;
        while (x < 300) : (x += 0.0625 + 0.001) try expect_rounding(T, reference, x);
        try std.testing.expect(std.math.isNan(round(std.math.nan(T))));
    }
}

fn expect_rounding(comptime T: type, comptime reference: type, x: T) !void {
    const Bits = @Int(.unsigned, @bitSizeOf(T));
    try std.testing.expectEqual(@as(Bits, @bitCast(reference.floor(x))), @as(Bits, @bitCast(floor(x))));
    try std.testing.expectEqual(@as(Bits, @bitCast(reference.ceil(x))), @as(Bits, @bitCast(ceil(x))));
    try std.testing.expectEqual(@as(Bits, @bitCast(reference.trunc(x))), @as(Bits, @bitCast(trunc(x))));
    try std.testing.expectEqual(@as(Bits, @bitCast(reference.round(x))), @as(Bits, @bitCast(round(x))));
}

test "single precision sine, cosine and tangent track the builtins" {
    const reference = @import("builtin_reference.zig");
    var x: f32 = -6000;
    while (x < 6000) : (x += 0.37) {
        try std.testing.expectApproxEqAbs(reference.sin(x), sin(x), 1e-6);
        try std.testing.expectApproxEqAbs(reference.cos(x), cos(x), 1e-6);
        // Error in the angle grows by the slope, 1 + tan^2, near the poles
        const t = reference.tan(x);
        try std.testing.expectApproxEqAbs(t, tan(x), 1e-6 * (1 + t * t));
    }
    // The slow reduction, past where the fast one is exact
    x = 6000;
    while (x < 1e6) : (x = x * 1.01 + 0.3) {
        try std.testing.expectApproxEqAbs(reference.sin(x), sin(x), 1e-6);
        try std.testing.expectApproxEqAbs(reference.cos(x), cos(x), 1e-6);
    }
    try std.testing.expect(std.math.isNan(sin(std.math.inf(f32))));
    try std.testing.expect(std.math.isNan(cos(std.math.nan(f32))));
    try std.testing.expect(@abs(sin(@as(f32, 3e38))) <= 1);
}

test "double precision sine and cosine track the builtins" {
    const reference = @import("builtin_reference.zig");
    var x: f64 = -1.5e6;
    while (x < 1.5e6) : (x += 97.13) {
        try std.testing.expectApproxEqAbs(reference.sin(x), sin(x), 1e-15);
        try std.testing.expectApproxEqAbs(reference.cos(x), cos(x), 1e-15);
    }
    x = -10;
    while (x < 10) : (x += 0.0137) {
        try std.testing.expectApproxEqRel(reference.sin(x), sin(x), 1e-15);
        try std.testing.expectApproxEqRel(reference.tan(x), tan(x), 1e-14);
    }
    try std.testing.expect(std.math.isNan(sin(std.math.inf(f64))));
}
