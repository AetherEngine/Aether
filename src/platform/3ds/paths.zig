const std = @import("std");

extern fn archiveMountSdmc() u32;
extern fn archiveUnmount(name: [*:0]const u8) u32;
extern fn romfsMountSelf(name: [*:0]const u8) u32;
extern fn romfsUnmount(name: [*:0]const u8) u32;

pub fn mountData() bool {
    return archiveMountSdmc() == 0;
}

pub fn unmountData() void {
    _ = archiveUnmount("sdmc");
}

pub fn mountResources() bool {
    return romfsMountSelf("romfs") == 0;
}

pub fn unmountResources() void {
    _ = romfsUnmount("romfs");
}

pub fn dataRoot(buffer: []u8, app_name: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buffer, "sdmc:/3ds/{s}", .{app_name}) catch error.NameTooLong;
}
