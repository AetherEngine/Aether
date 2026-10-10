//! PSP services exposed to applications as `aether.Psp`.
const dialogs = @import("dialogs.zig");

/// Shows the system network configuration dialog. True once connected.
pub const show_net_dialog = dialogs.show_net_dialog;
/// Runs the system on-screen keyboard over UTF-16 buffers.
pub const show_osk = dialogs.show_osk;
