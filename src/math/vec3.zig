x: f32,
y: f32,
z: f32,

const Vec3 = @This();

pub fn new(x: f32, y: f32, z: f32) Vec3 {
    return .{ .x = x, .y = y, .z = z };
}

pub fn zero() Vec3 {
    return .{ .x = 0, .y = 0, .z = 0 };
}

pub fn one() Vec3 {
    return .{ .x = 1, .y = 1, .z = 1 };
}

pub fn add(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
}

pub fn sub(a: Vec3, b: Vec3) Vec3 {
    return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
}

pub fn scale(v: Vec3, s: f32) Vec3 {
    return .{ .x = v.x * s, .y = v.y * s, .z = v.z * s };
}

pub fn negate(v: Vec3) Vec3 {
    return .{ .x = -v.x, .y = -v.y, .z = -v.z };
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{
        .x = a.y * b.z - a.z * b.y,
        .y = a.z * b.x - a.x * b.z,
        .z = a.x * b.y - a.y * b.x,
    };
}

pub fn lengthSq(v: Vec3) f32 {
    return v.x * v.x + v.y * v.y + v.z * v.z;
}

pub fn length(v: Vec3) f32 {
    return @sqrt(v.lengthSq());
}

pub fn normalize(v: Vec3) Vec3 {
    return v.scale(1.0 / v.length());
}
