const std = @import("std");
const c = @import("c.zig").switch_c;

pub fn mount_data() bool {
    return c.fsdevMountSdmc() == 0;
}

pub fn unmount_data() void {
    _ = c.fsdevUnmountDevice("sdmc");
}

pub fn mount_resources() bool {
    return c.romfsMountSelf("romfs") == 0;
}

pub fn unmount_resources() void {
    _ = c.romfsUnmount("romfs");
}

pub fn data_root(buffer: []u8, app_name: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buffer, "sdmc:/switch/{s}", .{app_name}) catch error.NameTooLong;
}
