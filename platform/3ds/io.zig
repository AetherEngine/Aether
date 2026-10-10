//! 3DS I/O facts. The base Io is Zitrus' Horizon Io. Zitrus selects std.Io's
//! vtable statically through `std_os_options`, so the application receives it
//! unchanged: `async` runs inline and `concurrent` is unavailable until
//! Horizon's Io spawns tasks itself. Background work uses `Util.Thread`.
const std = @import("std");
const Tasks = @import("../io.zig").Tasks;

pub const max_path_bytes: usize = std.Io.Dir.max_path_bytes;
pub const rename_replaces_destination = true;
pub const tasks: Tasks = .base;
