//! The builtins that `scalar.zig` replaces, for its tests to check against.
//! tiger_lint bans them everywhere else, so this file is excluded from it.
//! Import it from `test` blocks only.

const std = @import("std");

pub fn min(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @min(a, b);
}

pub fn max(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    return @max(a, b);
}

pub fn clamp(v: anytype, lo: @TypeOf(v), hi: @TypeOf(v)) @TypeOf(v) {
    return std.math.clamp(v, lo, hi);
}

pub fn floor(x: anytype) @TypeOf(x) {
    return @floor(x);
}

pub fn ceil(x: anytype) @TypeOf(x) {
    return @ceil(x);
}

pub fn trunc(x: anytype) @TypeOf(x) {
    return @trunc(x);
}

pub fn round(x: anytype) @TypeOf(x) {
    return @round(x);
}

pub fn sin(x: anytype) @TypeOf(x) {
    return @sin(x);
}

pub fn cos(x: anytype) @TypeOf(x) {
    return @cos(x);
}

pub fn tan(x: anytype) @TypeOf(x) {
    return @tan(x);
}
