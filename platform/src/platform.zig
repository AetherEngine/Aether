const std = @import("std");
const option = @import("options");

pub const Platforms = enum {
    Windows,
    MacOS,
    Linux,
    PSP,
};

pub const Platform: Platforms = if (std.mem.eql(u8, "windows", option.platform)) .Windows else if (std.mem.eql(u8, "macos", option.platform)) .MacOS else if (std.mem.eql(u8, "linux", option.platform)) .Linux else if (std.mem.eql(u8, "psp", option.platform)) .PSP else @compileError("Unknown platform");
