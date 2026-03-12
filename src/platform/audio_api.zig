const Vec3 = @import("../math/math.zig").Vec3;
const Clip = @import("../audio/clip.zig");
const Util = @import("../util/util.zig");
const Self = @This();

ptr: *anyopaque,
tab: *const VTable,

pub const VTable = struct {
    // --- API Setup / Lifecycle ---
    init: *const fn (ctx: *anyopaque) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,
    set_listener_position: *const fn (ctx: *anyopaque, pos: Vec3) void,
    set_listener_direction: *const fn (ctx: *anyopaque, dir: Vec3) void,

    // --- Audio Clip (raw) ---
    load_clip: *const fn (ctx: *anyopaque, path: [:0]const u8) anyerror!Clip.Handle,
    unload_clip: *const fn (ctx: *anyopaque, handle: Clip.Handle) void,
    play_clip: *const fn (ctx: *anyopaque, handle: Clip.Handle) void,
    stop_clip: *const fn (ctx: *anyopaque, handle: Clip.Handle) void,
    set_clip_position: *const fn (ctx: *anyopaque, handle: Clip.Handle, pos: Vec3) void,
};

/// Initializes the Audio API. Must be called before any other audio functions.
pub fn init(self: *const Self) anyerror!void {
    try self.tab.init(self.ptr);
}

/// Shuts down the Audio API and frees all associated resources.
pub fn deinit(self: *const Self) void {
    self.tab.deinit(self.ptr);
}

/// Factory function to create an AudioAPI instance appropriate for the current platform.
pub fn make_api() !Self {
    @panic("Audio Not Yet Implemented!");
}
