//! PSP I/O facts. The base Io is pspsdk's (`sdk.extra.Io.psp_io`), which its
//! start code passes to `entry.run`. It runs tasks on kernel threads sized by
//! `PspOptions.async_stack_size`.
const Tasks = @import("../io.zig").Tasks;

/// The PSP SDK uses 1024-byte path buffers, including the terminator.
pub const max_path_bytes: usize = 1024;
/// sceIoRename fails when the destination exists.
pub const rename_replaces_destination = false;
pub const tasks: Tasks = .base;
