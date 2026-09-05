const std = @import("std");
const assert = std.debug.assert;

const Rendering = @import("../rendering/rendering.zig");

pub const ref_width: u32 = 400;
pub const ref_height: u32 = 240;

comptime {
    assert(ref_width > 0);
    assert(ref_height > 0);
}

pub fn get() u32 {
    const size = Rendering.surface_size();
    return compute(size.width, size.height);
}

pub fn compute(screen_w: u32, screen_h: u32) u32 {
    if (screen_w == 0 or screen_h == 0) return 1;
    const sx = screen_w / ref_width;
    const sy = screen_h / ref_height;
    return @max(1, @min(sx, sy));
}
