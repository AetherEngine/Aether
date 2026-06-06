const std = @import("std");
const c = @import("../nintendo_c.zig").c;

pub fn mountData() bool {
    return c.fsdevMountSdmc() == 0;
}

pub fn unmountData() void {
    _ = c.fsdevUnmountDevice("sdmc");
}

pub fn mountResources() bool {
    return c.romfsMountSelf("romfs") == 0;
}

pub fn unmountResources() void {
    _ = c.romfsUnmount("romfs");
}

pub fn dataRoot(buffer: []u8, app_name: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buffer, "sdmc:/switch/{s}", .{app_name}) catch error.NameTooLong;
}
