const options = @import("options");

const audio_api = @import("audio_api.zig");

pub const Api = if (options.config.audio == .none)
    @import("headless/headless_audio.zig")
else switch (options.config.platform) {
    .psp => @import("psp/psp_audio.zig"),
    .nintendo_3ds => @import("3ds/audio.zig"),
    .nintendo_switch => @import("switch/switch_audio.zig"),
    .wasm => @import("wasm/browser_audio.zig"),
    else => @import("sdl/audio.zig"),
};

comptime {
    audio_api.assert_impl(Api);
}

// Dispatch new voices before the next 3DS output page, without a frame of delay.
pub const dispatch_on_play = options.config.platform == .nintendo_3ds;
