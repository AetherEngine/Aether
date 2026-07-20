pub const Color = packed struct(u32) {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }

    pub const none = rgba(0, 0, 0, 0);
    pub const white = rgba(255, 255, 255, 255);
    pub const black = rgba(0, 0, 0, 255);
    pub const gray = rgba(85, 85, 85, 255);
    pub const gold = rgba(255, 170, 0, 255);
};

comptime {
    @import("std").debug.assert(@sizeOf(Color) == 4);
}
