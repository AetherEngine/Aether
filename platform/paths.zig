const std = @import("std");
const assert = std.debug.assert;
const options = @import("options");

const Io = std.Io;
const NintendoIo = if (options.config.platform == .nintendo_switch)
    @import("c_io.zig")
else
    void;

/// Owned by Engine; pass these handles to asset and save-file APIs.
pub const Dirs = struct {
    /// Bundled assets; may alias CWD or `data`.
    resources: Io.Dir,
    /// Writable application data; may alias CWD.
    data: Io.Dir,

    pub fn close(self: *Dirs, io: Io) void {
        // CWD is borrowed; aliased handles must only be closed once.
        const cwd_handle = Io.Dir.cwd().handle;
        if (self.resources.handle != cwd_handle) self.resources.close(io);
        if (self.data.handle != cwd_handle and self.data.handle != self.resources.handle)
            self.data.close(io);

        if (NintendoIo != void) NintendoIo.deinitAppDirs();
    }
};

pub const Error = error{
    /// `HOME` (mac/linux) env var missing -- no way to derive user data dir.
    MissingHome,
    /// `APPDATA` (windows) env var missing.
    MissingAppData,
    /// Constructed path would exceed `Io.Dir.max_path_bytes`.
    PathTooLong,
} ||
    Io.Cancelable ||
    Io.UnexpectedError ||
    Io.Dir.OpenError ||
    Io.Dir.CreateDirPathOpenError ||
    std.process.ExecutablePathError;

/// Creates the application data directory if it does not exist.
pub fn resolve(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    app_name: []const u8,
) Error!Dirs {
    assert(app_name.len > 0);

    if (options.config.use_cwd) {
        if (NintendoIo != void) NintendoIo.useCwdDirs();
        return .{ .resources = Io.Dir.cwd(), .data = Io.Dir.cwd() };
    }

    return switch (options.config.platform) {
        .macos, .windows, .linux => resolve_desktop(io, environ_map, app_name),
        .nintendo_3ds => resolve_nintendo_3ds(io, app_name),
        .nintendo_switch => resolve_nintendo(io, app_name),
        else => .{ .resources = Io.Dir.cwd(), .data = Io.Dir.cwd() },
    };
}

fn resolve_nintendo_3ds(io: Io, app_name: []const u8) Error!Dirs {
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

fn resolve_nintendo(io: Io, app_name: []const u8) Error!Dirs {
    NintendoIo.mountData();
    errdefer NintendoIo.deinitAppDirs();

    var data_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data_path = NintendoIo.dataRoot(&data_buf, app_name) catch return error.PathTooLong;
    const data = try Io.Dir.cwd().createDirPathOpen(io, data_path, .{ .open_options = .{ .iterate = true } });
    errdefer data.close(io);

    const resources = if (NintendoIo.mountResources())
        Io.Dir.cwd().openDir(io, "romfs:/", .{}) catch data
    else
        data;

    return .{ .resources = resources, .data = data };
}

fn resolve_desktop(io: Io, environ_map: *const std.process.Environ.Map, app_name: []const u8) Error!Dirs {
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
