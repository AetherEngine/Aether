const std = @import("std");
const Vec3 = @import("../math/math.zig").Vec3;
const platform_audio = @import("../platform/audio.zig");
const options = @import("options");

// -- types -------------------------------------------------------------------

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

// -- forwarding to the instantiated mixer ------------------------------------

const mix = platform_audio.mix;

pub fn create_buffer(desc: *const SoundBufferDesc) CreateBufferError!SoundBufferHandle {
    return mix.create_buffer(desc);
}

pub fn adopt_buffer(allocator: std.mem.Allocator, bytes: []u8, format: PcmFormat) CreateBufferError!SoundBufferHandle {
    return mix.adopt_buffer(allocator, bytes, format);
}

pub fn load_wav(io: std.Io, dir: anytype, allocator: std.mem.Allocator, path: []const u8) LoadWavError!SoundBufferHandle {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    var temp: [4096]u8 = undefined;
    var reader = if (options.config.platform == .nintendo_switch)
        file.readerStreaming(io, &temp)
    else
        file.reader(io, &temp);

    var riff_hdr: [8]u8 = undefined;
    try reader.interface.readSliceAll(&riff_hdr);
    const file_size: usize = @as(usize, std.mem.readInt(u32, riff_hdr[4..8], .little)) + 8;

    const bytes = try allocator.alloc(u8, file_size);
    errdefer allocator.free(bytes);
    @memcpy(bytes[0..8], &riff_hdr);
    try reader.interface.readSliceAll(bytes[8..]);

    const desc = try wav.parse(bytes);
    return mix.adopt_parsed_wav(allocator, bytes, &desc);
}

pub fn destroy_buffer(handle: SoundBufferHandle) void {
    mix.destroy_buffer(handle);
}

pub fn create_stream(desc: *const StreamingSoundDesc) CreateStreamError!StreamingSoundHandle {
    return mix.create_stream(desc);
}

pub fn destroy_stream(handle: StreamingSoundHandle) void {
    mix.destroy_stream(handle);
}

pub fn play_buffer(buffer: SoundBufferHandle, opts: *const PlayOptions) PlayError!SoundHandle {
    return mix.play_buffer(buffer, opts);
}

pub fn play_buffer_at(buffer: SoundBufferHandle, pos: Vec3, opts: *const PlayOptions) PlayError!SoundHandle {
    return mix.play_buffer_at(buffer, pos, opts);
}

pub fn play_stream(stream: StreamingSoundHandle, opts: *const PlayOptions) PlayError!SoundHandle {
    return mix.play_stream(stream, opts);
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
