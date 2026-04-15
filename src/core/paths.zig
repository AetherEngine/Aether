//! Cross-platform per-app directories.
//!
//! Games write two kinds of files that want different locations:
//!
//!   * **Resources** — read-only assets shipped with the app (pack.zip,
//!     embedded shaders, icons). On macOS these live inside
//!     `<Bundle>.app/Contents/Resources/`; on desktop Linux/Windows they
//!     sit alongside the exe; on PSP they sit at CWD.
//!
//!   * **Data** — user-writable persistent state (world saves, logs,
//!     config, user-installed texture packs). OS-conventional locations
//!     apply here: `~/Library/Application Support/<app>` on macOS,
//!     `%APPDATA%\<app>` on Windows, `$XDG_DATA_HOME/<app>` on Linux.
//!
//! Both are exposed as open `std.Io.Dir` handles owned by the engine for
//! its lifetime. Callers pass the appropriate Dir into file-open APIs
//! (e.g. `dirs.resources.openFile(io, "pack.zip", .{})`) instead of
//! using `Io.Dir.cwd()`, which was the prior convention and broke when
//! CWD was not the app root (Finder-launched .app has CWD=/).
//!
//! Env-var access is routed through the caller-supplied
//! `std.process.Environ.Map`; this module never touches `std.c`,
//! `std.os`, or `std.posix` — paths are an engine-boundary concern but
//! per project style guide they go through `std.Io` / `std.process`.

const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const Io = std.Io;

/// Engine-owned directory handles. Cleared via `close()` at engine shutdown.
pub const Dirs = struct {
    /// Read-only assets shipped with the app. On platforms where the
    /// concept doesn't apply, points at CWD.
    resources: Io.Dir,
    /// User-writable persistent state. On platforms where the concept
    /// doesn't apply, points at CWD (same handle as `resources`).
    data: Io.Dir,

    pub fn close(self: *Dirs, io: Io) void {
        // On CWD-fallback platforms resources and data are the same
        // handle; closing a cwd handle is a no-op regardless.
        self.resources.close(io);
        self.data.close(io);
    }
};

pub const Error = error{
    /// `HOME` (mac/linux) env var missing — no way to derive user data dir.
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

/// Resolve per-app directories for the current platform.
///
/// `app_name` is used as the leaf directory name under the per-user
/// data root (e.g. `~/Library/Application Support/<app_name>/`). The
/// data directory is created if missing.
pub fn resolve(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    app_name: []const u8,
) Error!Dirs {
    std.debug.assert(app_name.len > 0);

    // Build-time `-Duse-cwd=true` short-circuits the platform layout and
    // points both dirs at CWD. Handy for `zig build run-game` iteration
    // and debug/CI builds where state co-located with the binary is a
    // feature, not a bug.
    if (options.config.use_cwd) {
        return .{ .resources = Io.Dir.cwd(), .data = Io.Dir.cwd() };
    }

    return switch (builtin.os.tag) {
        .macos => resolve_macos(io, environ_map, app_name),
        .windows => resolve_windows(io, environ_map, app_name),
        .linux => resolve_linux(io, environ_map, app_name),
        // PSP: both dirs collapse to CWD. The EBOOT and its siblings all
        // live under `ms0:/PSP/GAME/<id>/`; the runtime sets CWD there
        // before main. No separation to enforce.
        //
        // Vita/others: placeholder until those ports land. Same CWD
        // fallback keeps early bring-up builds working with zero
        // platform-specific code.
        else => .{ .resources = Io.Dir.cwd(), .data = Io.Dir.cwd() },
    };
}

// -- macOS --------------------------------------------------------------------

fn resolve_macos(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    app_name: []const u8,
) Error!Dirs {
    var exe_dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const exe_dir_len = try std.process.executableDirPath(io, &exe_dir_buf);
    const exe_dir = exe_dir_buf[0..exe_dir_len];

    const resources = try open_macos_resources(io, exe_dir);

    const home = environ_map.get("HOME") orelse return error.MissingHome;
    var data_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data_path = std.fmt.bufPrint(
        &data_buf,
        "{s}/Library/Application Support/{s}",
        .{ home, app_name },
    ) catch return error.PathTooLong;
    const data = try Io.Dir.cwd().createDirPathOpen(io, data_path, .{ .open_options = .{ .iterate = true } });

    return .{ .resources = resources, .data = data };
}

/// Resources dir is `<Bundle>.app/Contents/Resources/` when launched from
/// an .app bundle (exe is at `.../<Bundle>.app/Contents/MacOS/<exe>`).
/// For `zig build run-game` / a loose exe layout, fall back to the exe's
/// dir so dev builds still find CWD-style resources.
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

// -- Windows ------------------------------------------------------------------

fn resolve_windows(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    app_name: []const u8,
) Error!Dirs {
    var exe_dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const exe_dir_len = try std.process.executableDirPath(io, &exe_dir_buf);
    const resources = try Io.Dir.openDirAbsolute(io, exe_dir_buf[0..exe_dir_len], .{});

    const appdata = environ_map.get("APPDATA") orelse return error.MissingAppData;
    var data_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data_path = std.fmt.bufPrint(&data_buf, "{s}\\{s}", .{ appdata, app_name }) catch
        return error.PathTooLong;
    const data = try Io.Dir.cwd().createDirPathOpen(io, data_path, .{ .open_options = .{ .iterate = true } });
    return .{ .resources = resources, .data = data };
}

// -- Linux --------------------------------------------------------------------

fn resolve_linux(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    app_name: []const u8,
) Error!Dirs {
    var exe_dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const exe_dir_len = try std.process.executableDirPath(io, &exe_dir_buf);
    const resources = try Io.Dir.openDirAbsolute(io, exe_dir_buf[0..exe_dir_len], .{});

    // XDG Base Directory Specification: prefer $XDG_DATA_HOME, fall back to
    // $HOME/.local/share. Both branches format into the same stack buffer.
    var data_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const data_path = if (environ_map.get("XDG_DATA_HOME")) |xdg|
        std.fmt.bufPrint(&data_buf, "{s}/{s}", .{ xdg, app_name }) catch
            return error.PathTooLong
    else blk: {
        const home = environ_map.get("HOME") orelse return error.MissingHome;
        break :blk std.fmt.bufPrint(&data_buf, "{s}/.local/share/{s}", .{ home, app_name }) catch
            return error.PathTooLong;
    };
    const data = try Io.Dir.cwd().createDirPathOpen(io, data_path, .{ .open_options = .{ .iterate = true } });
    return .{ .resources = resources, .data = data };
}
