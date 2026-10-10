//! Switch directories: data under `sdmc:/switch/<app>`, resources in the
//! application's RomFS. Both devices are mounted on resolve and unmounted on
//! release.
const std = @import("std");
const c = @import("c.zig").switch_c;
const io = @import("io.zig");
const paths = @import("../paths.zig");

const Io = std.Io;

var data_mounted = false;
var resources_mounted = false;

pub fn resolve(sys_io: Io, _: *const std.process.Environ.Map, app_name: []const u8) paths.Error!paths.Dirs {
    data_mounted = c.fsdevMountSdmc() == 0;
    errdefer release();

    var data_buf: [io.max_path_bytes]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "sdmc:/switch/{s}", .{app_name}) catch return error.PathTooLong;
    const data = try Io.Dir.cwd().createDirPathOpen(sys_io, data_path, .{ .open_options = .{ .iterate = true } });
    errdefer data.close(sys_io);

    resources_mounted = c.romfsMountSelf("romfs") == 0;
    const resources = if (resources_mounted)
        Io.Dir.cwd().openDir(sys_io, "romfs:/", .{}) catch data
    else
        data;

    return .{ .resources = resources, .data = data };
}

pub fn release() void {
    io.reset_dirs();
    if (resources_mounted) {
        _ = c.romfsUnmount("romfs");
        resources_mounted = false;
    }
    if (data_mounted) {
        _ = c.fsdevUnmountDevice("sdmc");
        data_mounted = false;
    }
}
