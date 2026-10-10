//! Switch I/O facts and the base Io, implemented over newlib/libnx in
//! `newlib_io.zig`. That Io has no concurrency, so AetherIo runs tasks on
//! libnx threads.
const std = @import("std");
const newlib_io = @import("newlib_io.zig");
const Tasks = @import("../io.zig").Tasks;

/// libnx uses 1024-byte path buffers, including the terminator.
pub const max_path_bytes: usize = 1024;
pub const rename_replaces_destination = true;
pub const tasks: Tasks = .{ .native_threads = .{ .stack_size = 2 * 1024 * 1024 } };

pub fn base() std.Io {
    return newlib_io.io();
}

pub const cwd = newlib_io.cwd;
/// The `root.os` namespace std reads for path limits.
pub const std_os = newlib_io.std_os_limits;
/// Forgets directories opened through the base Io; call after closing them.
pub const reset_dirs = newlib_io.resetDirs;
/// Starts libnx's socket service on first use; safe from any thread.
pub const ensure_networking = newlib_io.ensureNetworking;
pub const deinit_networking = newlib_io.deinitNetworking;
