//! PSP directories: resources and data both live beside EBOOT.PBP.
const std = @import("std");
const paths = @import("../paths.zig");

pub fn resolve(_: std.Io, _: *const std.process.Environ.Map, _: []const u8) paths.Error!paths.Dirs {
    return paths.cwd_dirs();
}

pub fn release() void {}
