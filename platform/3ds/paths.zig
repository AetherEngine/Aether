//! 3DS directories: data under `sdmc:/3ds/<app>`, resources in the RomFS
//! the entry mounts at startup.
const std = @import("std");
const paths = @import("../paths.zig");

const Io = std.Io;

pub fn resolve(io: Io, _: *const std.process.Environ.Map, app_name: []const u8) paths.Error!paths.Dirs {
    var data_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "sdmc:/3ds/{s}", .{app_name}) catch return error.PathTooLong;
    const cwd = Io.Dir.cwd();

    const data = cwd.createDirPathOpen(io, data_path, .{ .open_options = .{ .iterate = true } }) catch
        cwd.openDir(io, "sdmc:/", .{ .iterate = true }) catch
        cwd;
    errdefer if (data.handle != cwd.handle) data.close(io);

    const resources = cwd.openDir(io, "romfs:/", .{}) catch data;

    return .{ .resources = resources, .data = data };
}

pub fn release() void {}
