const std = @import("std");

x: f32,
y: f32,
z: f32,

const Self = @This();

pub fn new(x: f32, y: f32, z: f32) Self {
    return .{ .x = x, .y = y, .z = z };
}

pub fn zero() Self {
    return .{ .x = 0, .y = 0, .z = 0 };
}

pub fn one() Self {
    return .{ .x = 1, .y = 1, .z = 1 };
}

pub fn add(a: Self, b: Self) Self {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

pub fn sub(a: Self, b: Self) Self {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}

pub fn scale(v: Self, s: f32) Self {
    return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
}

pub fn negate(v: Self) Self {
    return .{ .x = -v.x, .y = -v.y, .z = -v.z };
}

pub fn dot(a: Self, b: Self) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

pub fn cross(a: Self, b: Self) Self {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

pub fn lengthSq(v: Self) f32 {
    return v.x * v.x + v.y * v.y + v.z * v.z;
}

pub fn length(v: Self) f32 {
    return @sqrt(v.lengthSq());
}

pub fn normalize(v: Self) Self {
    return v.scale(1.0 / v.length());
}
