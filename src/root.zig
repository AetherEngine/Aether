const std = @import("std");
const options = @import("options");

pub const Core = @import("core/core.zig");
pub const Util = @import("util/util.zig");
pub const Rendering = @import("rendering/rendering.zig");
pub const Math = @import("math/math.zig");
pub const App = @import("app.zig");

/// Comptime-known platform and graphics backend, resolved from build options.
/// User code can switch on these for per-platform configuration without
/// importing the build options module directly.
pub const Platform = options.@"build.Platform";
pub const Gfx = options.@"build.Gfx";
pub const platform: Platform = options.config.platform;
pub const gfx: Gfx = options.config.gfx;

comptime {
    std.testing.refAllDecls(@This());
}
