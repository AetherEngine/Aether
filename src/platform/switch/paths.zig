const std = @import("std");

extern fn fsdevMountSdmc() u32;
extern fn romfsMountSelf(name: [*:0]const u8) u32;

pub fn mountResources() bool {
    _ = fsdevMountSdmc();
    return romfsMountSelf("romfs") == 0;
}

pub fn dataRoot(buffer: []u8, app_name: []const u8) error{NameTooLong}![]const u8 {
    return std.fmt.bufPrint(buffer, "sdmc:/switch/{s}", .{app_name}) catch error.NameTooLong;
}
