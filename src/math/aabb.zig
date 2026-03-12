const Vec3 = @import("vec3.zig");

min: Vec3,
max: Vec3,

const Self = @This();

pub fn fromCenterHalfExtents(c: Vec3, half: Vec3) Self {
    return .{
        .min = Vec3.sub(c, half),
        .max = Vec3.add(c, half),
    };
}

pub fn containsPoint(self: Self, p: Vec3) bool {
    return p.x >= self.min.x and p.x <= self.max.x and
        p.y >= self.min.y and p.y <= self.max.y and
        p.z >= self.min.z and p.z <= self.max.z;
}

pub fn intersects(a: Self, b: Self) bool {
    return a.min.x <= b.max.x and a.max.x >= b.min.x and
        a.min.y <= b.max.y and a.max.y >= b.min.y and
        a.min.z <= b.max.z and a.max.z >= b.min.z;
}

pub fn expand(self: Self, p: Vec3) Self {
    return .{
        .min = Vec3.new(
            @min(self.min.x, p.x),
            @min(self.min.y, p.y),
            @min(self.min.z, p.z),
        ),
        .max = Vec3.new(
            @max(self.max.x, p.x),
            @max(self.max.y, p.y),
            @max(self.max.z, p.z),
        ),
    };
}

pub fn center(self: Self) Vec3 {
    return Vec3.scale(Vec3.add(self.min, self.max), 0.5);
}

pub fn halfExtents(self: Self) Vec3 {
    return Vec3.scale(Vec3.sub(self.max, self.min), 0.5);
}
