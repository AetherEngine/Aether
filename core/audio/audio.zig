const std = @import("std");
const Vec3 = @import("platform").math.Vec3;
const platform_audio = @import("platform").audio;
const options = @import("options");

pub const stream_mod = @import("stream.zig");
pub const PcmFormat = stream_mod.PcmFormat;
pub const SoundBufferHandle = stream_mod.SoundBufferHandle;
pub const StreamingSoundHandle = stream_mod.StreamingSoundHandle;
pub const SoundBufferDesc = stream_mod.SoundBufferDesc;
pub const StreamingSoundDesc = stream_mod.StreamingSoundDesc;
pub const SlotSource = stream_mod.SlotSource;
pub const wav = @import("wav.zig");

pub const mixer_mod = @import("mixer.zig");
pub const SoundHandle = mixer_mod.SoundHandle;
pub const PlayOptions = mixer_mod.PlayOptions;
pub const PlayError = mixer_mod.PlayError;
pub const Priority = mixer_mod.Priority;
pub const CreateBufferError = mixer_mod.CreateBufferError;
pub const CreateStreamError = mixer_mod.CreateStreamError;
pub const enabled = options.config.audio != .none;

pub const LoadWavError = CreateBufferError ||
    wav.Error ||
    std.mem.Allocator.Error ||
    std.Io.Reader.Error ||
    std.Io.File.OpenError;

const mix = mixer_mod.MixerType(platform_audio.Api);

pub const init = mix.init;
pub const deinit = mix.deinit;
pub const update = mix.update;

pub const create_buffer = mix.create_buffer;
pub const adopt_buffer = mix.adopt_buffer;
pub const destroy_buffer = mix.destroy_buffer;
pub const create_stream = mix.create_stream;
pub const create_owned_stream = mix.create_owned_stream;
pub const create_wav_stream = mix.create_wav_stream;
pub const destroy_stream = mix.destroy_stream;
pub const stop = mix.stop;
pub const set_position = mix.set_position;
pub const set_volume = mix.set_volume;
pub const is_playing = mix.is_playing;
pub const set_listener = mix.set_listener;

pub fn load_wav(io: std.Io, dir: anytype, allocator: std.mem.Allocator, path: []const u8) LoadWavError!SoundBufferHandle {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var temp: [4096]u8 = undefined;
    var reader = file.readerStreaming(io, &temp);

    var riff_hdr: [8]u8 = undefined;
    try reader.interface.readSliceAll(&riff_hdr);
    if (!std.mem.eql(u8, riff_hdr[0..4], "RIFF")) return error.InvalidWav;
    const file_size = std.math.add(usize, std.mem.readInt(u32, riff_hdr[4..8], .little), 8) catch return error.InvalidWav;
    if (file_size < 12) return error.InvalidWav;

    const bytes = try allocator.alloc(u8, file_size);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..8], &riff_hdr);
    try reader.interface.readSliceAll(bytes[8..]);

    const desc = try wav.parse(bytes);
    return mix.adopt_parsed_wav(allocator, bytes, &desc);
}

pub fn play_buffer(buffer: SoundBufferHandle, opts: *const PlayOptions) PlayError!SoundHandle {
    const handle = try mix.play_buffer(buffer, opts);
    if (platform_audio.dispatch_on_play) mix.update();
    return handle;
}

pub fn play_buffer_at(buffer: SoundBufferHandle, pos: Vec3, opts: *const PlayOptions) PlayError!SoundHandle {
    const handle = try mix.play_buffer_at(buffer, pos, opts);
    if (platform_audio.dispatch_on_play) mix.update();
    return handle;
}

pub fn play_stream(stream: StreamingSoundHandle, opts: *const PlayOptions) PlayError!SoundHandle {
    const handle = try mix.play_stream(stream, opts);
    if (platform_audio.dispatch_on_play) mix.update();
    return handle;
}
