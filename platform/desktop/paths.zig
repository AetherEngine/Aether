//! Desktop directories: resources beside the executable (or in the .app
//! bundle), data in the per-user application data directory.
const std = @import("std");
const options = @import("options");
const paths = @import("../paths.zig");

const Io = std.Io;
const Error = paths.Error;

pub fn resolve(io: Io, environ_map: *const std.process.Environ.Map, app_name: []const u8) Error!paths.Dirs {
    var exe_dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const exe_dir_len = try std.process.executableDirPath(io, &exe_dir_buf);
    const exe_dir = exe_dir_buf[0..exe_dir_len];
    const resources = if (options.config.platform == .macos)
        try open_macos_resources(io, exe_dir)
    else
        try Io.Dir.openDirAbsolute(io, exe_dir, .{});
    errdefer resources.close(io);

    var data_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data_path = switch (options.config.platform) {
        .macos => std.fmt.bufPrint(&data_buf, "{s}/Library/Application Support/{s}", .{
            environ_map.get("HOME") orelse return error.MissingHome, app_name,
        }),
        .windows => std.fmt.bufPrint(&data_buf, "{s}\\{s}", .{
            environ_map.get("APPDATA") orelse return error.MissingAppData, app_name,
        }),
        .linux => if (environ_map.get("XDG_DATA_HOME")) |xdg|
            std.fmt.bufPrint(&data_buf, "{s}/{s}", .{ xdg, app_name })
        else
            std.fmt.bufPrint(&data_buf, "{s}/.local/share/{s}", .{
                environ_map.get("HOME") orelse return error.MissingHome, app_name,
            }),
        else => unreachable,
    } catch return error.PathTooLong;
    const data = try Io.Dir.cwd().createDirPathOpen(io, data_path, .{ .open_options = .{ .iterate = true } });
    return .{ .resources = resources, .data = data };
}

fn open_macos_resources(io: Io, exe_dir: []const u8) Error!Io.Dir {
    const macos_suffix = "/Contents/MacOS";
    const bundle_ok = std.mem.endsWith(u8, exe_dir, macos_suffix) and
        exe_dir.len > macos_suffix.len;

    if (bundle_ok) {
        const contents = exe_dir[0 .. exe_dir.len - "/MacOS".len];
        if (std.fs.path.dirname(contents)) |app_dir| {
            if (std.mem.endsWith(u8, app_dir, ".app")) {
                var res_buf: [Io.Dir.max_path_bytes]u8 = undefined;
                const res_path = std.fmt.bufPrint(&res_buf, "{s}/Resources", .{contents}) catch
                    return error.PathTooLong;
                return Io.Dir.openDirAbsolute(io, res_path, .{});
            }
        }
    }
    return Io.Dir.openDirAbsolute(io, exe_dir, .{});
}

pub fn release() void {}
