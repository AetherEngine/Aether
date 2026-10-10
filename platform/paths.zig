//! Application directories. Each target's `paths.zig` decides where bundled
//! resources and writable data live; `use_cwd` bypasses that for every target.
const std = @import("std");
const assert = std.debug.assert;
const options = @import("options");
const contract = @import("contract.zig");

const Io = std.Io;
const Backend = @import("backend.zig").target.paths;

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

        Backend.release();
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

pub const Interface = struct {
    /// Creates the application data directory if it does not exist.
    resolve: fn (Io, *const std.process.Environ.Map, []const u8) Error!Dirs,
    /// Releases target mounts after the directories are closed.
    release: fn () void,
};

comptime {
    contract.assert_impl("paths", Backend, Interface);
}

/// Creates the application data directory if it does not exist.
pub fn resolve(
    io: Io,
    environ_map: *const std.process.Environ.Map,
    app_name: []const u8,
) Error!Dirs {
    assert(app_name.len > 0);

    if (options.config.use_cwd) return cwd_dirs();
    return Backend.resolve(io, environ_map, app_name);
}

/// Resources and data both in the current directory.
pub fn cwd_dirs() Dirs {
    return .{ .resources = Io.Dir.cwd(), .data = Io.Dir.cwd() };
}
