const std = @import("std");
const Vec3 = @import("../math/math.zig").Vec3;
const platform_audio = @import("../platform/audio.zig");

// -- types -------------------------------------------------------------------

pub const stream_mod = @import("stream.zig");
pub const Stream = stream_mod.Stream;
pub const PcmFormat = stream_mod.PcmFormat;
pub const wav = @import("wav.zig");

pub const mixer_mod = @import("mixer.zig");
pub const SoundHandle = mixer_mod.SoundHandle;
pub const PlayOptions = mixer_mod.PlayOptions;
pub const Priority = mixer_mod.Priority;

// -- forwarding to the instantiated mixer ------------------------------------

const mix = platform_audio.mix;

pub fn play(s: Stream, opts: PlayOptions) !SoundHandle {
    return mix.play(s, opts);
}

pub fn play_at(s: Stream, pos: Vec3, opts: PlayOptions) !SoundHandle {
    return mix.play_at(s, pos, opts);
}

pub fn stop(handle: SoundHandle) void {
    mix.stop(handle);
}

pub fn set_position(handle: SoundHandle, pos: Vec3) void {
    mix.set_position(handle, pos);
}

pub fn set_volume(handle: SoundHandle, vol: f32) void {
    mix.set_volume(handle, vol);
}

pub fn is_playing(handle: SoundHandle) bool {
    return mix.is_playing(handle);
}

pub fn set_listener(pos: Vec3, forward: Vec3, up: Vec3) void {
    mix.set_listener(pos, forward, up);
}
