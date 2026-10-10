//! Desktop I/O facts. The base Io is the std.Io.Threaded instance std's start
//! code passes to `entry.run`; its thread pool runs tasks and supports
//! cancellation.
const std = @import("std");
const Tasks = @import("../io.zig").Tasks;

pub const max_path_bytes: usize = std.Io.Dir.max_path_bytes;
pub const rename_replaces_destination = true;
pub const tasks: Tasks = .base;
