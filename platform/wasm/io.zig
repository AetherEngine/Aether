//! Browser I/O facts. The base Io is std's single-threaded Io over WASI.
//! The page runs on one JS event-loop thread: `async` runs inline and
//! `concurrent` is unavailable.
const std = @import("std");
const Tasks = @import("../io.zig").Tasks;

pub const max_path_bytes: usize = std.Io.Dir.max_path_bytes;
pub const rename_replaces_destination = true;
pub const tasks: Tasks = .base;

pub fn base() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}
