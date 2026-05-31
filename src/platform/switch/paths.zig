const std = @import("std");

extern fn fsdevMountSdmc() u32;
extern fn fsdevUnmountDevice(name: [*:0]const u8) c_int;
extern fn romfsMountSelf(name: [*:0]const u8) u32;
extern fn romfsUnmount(name: [*:0]const u8) u32;

pub fn mountData() bool {
    return fsdevMountSdmc() == 0;
}

pub fn unmountData() void {
    _ = fsdevUnmountDevice("sdmc");
}

pub fn mountResources() bool {
    return romfsMountSelf("romfs") == 0;
}

pub fn unmountResources() void {
    _ = romfsUnmount("romfs");
}

pub fn dataRoot(buffer: []u8, app_name: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buffer, "sdmc:/switch/{s}", .{app_name}) catch error.NameTooLong;
}
