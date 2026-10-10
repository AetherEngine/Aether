//! 3DS services exposed to applications as `aether.N3ds`.
const app = @import("app.zig");

/// Whether the running console is a New Nintendo 3DS-family system.
pub const is_new = app.is_new;
/// The Horizon application the entry started, for direct service access.
pub const current_application = app.current_application;
