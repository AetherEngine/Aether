const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

const audio_api = @import("audio_api.zig");
const mixer_mod = @import("../audio/mixer.zig");

/// Comptime-selected audio backend module (slot-based PCM output).
pub const Api = if (options.config.gfx == .headless)
    @import("headless/headless_audio.zig")
else if (builtin.os.tag == .psp)
    @import("psp/psp_audio.zig")
else
    @import("glfw/audio.zig");

comptime {
    audio_api.assert_impl(Api);
}

/// Platform-independent voice scheduler, wired to the selected backend.
pub const mix = mixer_mod.Mixer(Api);

pub fn init(alloc: std.mem.Allocator, io: std.Io) !void {
    Api.setup(alloc, io);
    try mix.init();
}

pub fn update() void {
    mix.update();
}

pub fn deinit() void {
    mix.deinit();
}
