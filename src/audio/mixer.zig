const std = @import("std");
const Vec3 = @import("../math/math.zig").Vec3;
const Util = @import("../util/util.zig");
const stream_mod = @import("stream.zig");

pub const SoundHandleTag = enum {};
pub const SoundHandle = Util.Handle(SoundHandleTag);

pub const SoundBufferHandle = stream_mod.SoundBufferHandle;
pub const StreamingSoundHandle = stream_mod.StreamingSoundHandle;
pub const SoundBufferDesc = stream_mod.SoundBufferDesc;
pub const StreamingSoundDesc = stream_mod.StreamingSoundDesc;
pub const SlotSource = stream_mod.SlotSource;

pub const Priority = enum(u8) {
    low,
    normal,
    high,
    /// Always gets a slot, never culled.
    critical,
};

pub const PlayOptions = struct {
    volume: f32 = 1.0,
    priority: Priority = .normal,
    /// Distance at which volume is unattenuated.
    ref_distance: f32 = 1.0,
    /// Distance beyond which the voice is silent.
    max_distance: f32 = 100.0,
};

pub const CreateBufferError = error{
    InvalidSoundData,
    TooManySoundBuffers,
};

pub const CreateStreamError = error{
    TooManyStreamingSounds,
};

pub const PlayError = error{
    TooManyVoices,
    InvalidSoundBuffer,
    InvalidStreamingSound,
    StreamAlreadyPlaying,
};

const OwnedBuffer = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
};

const SoundBufferResource = struct {
    format: stream_mod.PcmFormat,
    pcm: []const u8,
    owned: ?OwnedBuffer = null,
};

const StreamingSoundResource = struct {
    reader: *std.Io.Reader,
    format: stream_mod.PcmFormat,
    byte_length: ?u64,
    active_voice: ?SoundHandle = null,
};

const VoiceSource = union(enum) {
    buffer: SoundBufferHandle,
    stream: StreamingSoundHandle,
};

/// Platform-independent voice scheduler. Manages a pool of virtual voices
/// and assigns the highest-priority ones to real backend slots each tick.
///
/// `Backend` must satisfy the slot-based audio_api.Interface.
pub fn Mixer(comptime Backend: type) type {
    return struct {
        pub const MAX_VOICES: usize = 64;
        pub const MAX_BUFFERS: usize = 256;
        pub const MAX_STREAMS: usize = 64;
        const MAX_SLOTS: usize = 32;

        const BufferTable = Util.ResourceTable(SoundBufferResource, MAX_BUFFERS + 1, SoundBufferHandle);
        const StreamTable = Util.ResourceTable(StreamingSoundResource, MAX_STREAMS + 1, StreamingSoundHandle);

        const VirtualVoice = struct {
            source: VoiceSource,
            cursor: std.atomic.Value(usize),
            position: ?Vec3,
            volume: f32,
            priority: Priority,
            ref_distance: f32,
            max_distance: f32,
            slot: ?u8,
            handle: SoundHandle,
        };

        var buffers = BufferTable.init();
        var streams = StreamTable.init();
        var voices: [MAX_VOICES]?VirtualVoice = @splat(null);
        var voice_generations: [MAX_VOICES]u8 = @splat(1);
        var listener_pos: Vec3 = Vec3.zero();
        var listener_fwd: Vec3 = Vec3.new(0, 0, -1);
        var listener_up: Vec3 = Vec3.new(0, 1, 0);

        // -- lifecycle -------------------------------------------------------

        pub fn init() @import("../platform/audio_api.zig").InitError!void {
            try Backend.init();
        }

        pub fn deinit() void {
            for (0..MAX_VOICES) |i| {
                if (voices[i] != null) {
                    if (voices[i].?.slot) |s| Backend.stop_slot(s);
                    release_voice(i);
                }
            }
            for (1..MAX_BUFFERS + 1) |i| {
                if (buffers.slots[i]) |resource| {
                    if (resource.owned) |owned| owned.allocator.free(owned.bytes);
                }
            }
            buffers.clear();
            streams.clear();
            Backend.deinit();
        }

        // -- resources -------------------------------------------------------

        pub fn create_buffer(desc: *const SoundBufferDesc) CreateBufferError!SoundBufferHandle {
            try validate_buffer(desc.format, desc.pcm);
            return buffers.add(.{
                .format = desc.format,
                .pcm = desc.pcm,
            }) orelse error.TooManySoundBuffers;
        }

        pub fn adopt_buffer(allocator: std.mem.Allocator, bytes: []u8, format: stream_mod.PcmFormat) CreateBufferError!SoundBufferHandle {
            try validate_buffer(format, bytes);
            return buffers.add(.{
                .format = format,
                .pcm = bytes,
                .owned = .{ .allocator = allocator, .bytes = bytes },
            }) orelse error.TooManySoundBuffers;
        }

        pub fn adopt_parsed_wav(allocator: std.mem.Allocator, bytes: []u8, desc: *const SoundBufferDesc) CreateBufferError!SoundBufferHandle {
            try validate_buffer(desc.format, desc.pcm);
            return buffers.add(.{
                .format = desc.format,
                .pcm = desc.pcm,
                .owned = .{ .allocator = allocator, .bytes = bytes },
            }) orelse error.TooManySoundBuffers;
        }

        pub fn destroy_buffer(handle: SoundBufferHandle) void {
            stop_voices_for_buffer(handle);
            const resource = buffers.get(handle) orelse return;
            _ = buffers.remove(handle);
            if (resource.owned) |owned| owned.allocator.free(owned.bytes);
        }

        pub fn create_stream(desc: *const StreamingSoundDesc) CreateStreamError!StreamingSoundHandle {
            return streams.add(.{
                .reader = desc.reader,
                .format = desc.format,
                .byte_length = desc.byte_length,
            }) orelse error.TooManyStreamingSounds;
        }

        pub fn destroy_stream(handle: StreamingSoundHandle) void {
            if (streams.get(handle)) |resource| {
                if (resource.active_voice) |voice| stop(voice);
            }
            _ = streams.remove(handle);
        }

        // -- listener --------------------------------------------------------

        pub fn set_listener(pos: Vec3, forward: Vec3, up: Vec3) void {
            listener_pos = pos;
            listener_fwd = forward;
            listener_up = up;
        }

        // -- voice control ---------------------------------------------------

        /// Play a non-positional sound (music, UI). Never distance-culled.
        pub fn play_buffer(buffer: SoundBufferHandle, opts: *const PlayOptions) PlayError!SoundHandle {
            return play_internal(.{ .buffer = buffer }, null, opts);
        }

        /// Play a positional sound. Subject to attenuation and slot priority.
        pub fn play_buffer_at(buffer: SoundBufferHandle, pos: Vec3, opts: *const PlayOptions) PlayError!SoundHandle {
            return play_internal(.{ .buffer = buffer }, pos, opts);
        }

        pub fn play_stream(stream: StreamingSoundHandle, opts: *const PlayOptions) PlayError!SoundHandle {
            return play_internal(.{ .stream = stream }, null, opts);
        }

        pub fn stop(handle: SoundHandle) void {
            if (find_index(handle)) |i| {
                if (voices[i].?.slot) |s| Backend.stop_slot(s);
                release_voice(i);
            }
        }

        pub fn set_position(handle: SoundHandle, pos: Vec3) void {
            if (find_index(handle)) |i| {
                voices[i].?.position = pos;
            }
        }

        pub fn set_volume(handle: SoundHandle, vol: f32) void {
            if (find_index(handle)) |i| {
                voices[i].?.volume = vol;
            }
        }

        pub fn is_playing(handle: SoundHandle) bool {
            return find_index(handle) != null;
        }

        // -- per-frame update ------------------------------------------------

        pub fn update() void {
            Backend.update();

            const max_slots: usize = @min(Backend.max_voices(), MAX_SLOTS);

            // 1. Reap voices whose backend slot finished (stream exhausted).
            for (0..MAX_VOICES) |i| {
                if (voices[i] != null) {
                    if (voices[i].?.slot) |s| {
                        if (!Backend.is_slot_active(s)) {
                            release_voice(i);
                        }
                    }
                }
            }

            // 2. Score every active voice.
            var scores: [MAX_VOICES]f32 = @splat(-1.0);
            var order: [MAX_VOICES]u8 = undefined;
            var count: usize = 0;

            for (0..MAX_VOICES) |i| {
                if (voices[i]) |v| {
                    scores[i] = effective_score(v);
                    order[count] = @intCast(i);
                    count += 1;
                }
            }

            // 3. Sort by score descending (insertion sort -- count <= 64).
            if (count > 1) {
                for (1..count) |i| {
                    const key = order[i];
                    const key_score = scores[key];
                    var j: usize = i;
                    while (j > 0 and scores[order[j - 1]] < key_score) {
                        order[j] = order[j - 1];
                        j -= 1;
                    }
                    order[j] = key;
                }
            }

            // 4. Evict voices outside the top N that hold a slot.
            for (@min(count, max_slots)..count) |rank| {
                const vi = order[rank];
                if (voices[vi].?.slot) |s| {
                    Backend.stop_slot(s);
                    voices[vi].?.slot = null;
                }
            }

            // 5. Build a used-slot mask from voices that kept their slots.
            var used: [MAX_SLOTS]bool = @splat(false);
            for (0..@min(count, max_slots)) |rank| {
                const vi = order[rank];
                if (voices[vi].?.slot) |s| {
                    used[s] = true;
                }
            }

            // 6. Assign free slots to promoted voices (top N without a slot).
            for (0..@min(count, max_slots)) |rank| {
                const vi = order[rank];
                if (voices[vi].?.slot == null) {
                    if (scores[vi] <= 0) continue; // beyond max_distance
                    const source = slot_source(vi) orelse {
                        release_voice(vi);
                        continue;
                    };
                    if (find_free_slot(&used, max_slots)) |s| {
                        Backend.play_slot(s, source) catch continue;
                        voices[vi].?.slot = s;
                        used[s] = true;
                    }
                }
            }

            // 7. Push gain / pan to every occupied slot.
            for (0..MAX_VOICES) |i| {
                if (voices[i]) |v| {
                    if (v.slot) |s| {
                        const gp = compute_gain_pan(v);
                        Backend.set_slot_gain_pan(s, gp.gain, gp.pan);
                    }
                }
            }
        }

        // -- internals -------------------------------------------------------

        fn validate_buffer(format: stream_mod.PcmFormat, pcm: []const u8) CreateBufferError!void {
            const frame_size = format.frame_size();
            if (frame_size == 0 or pcm.len == 0 or pcm.len % frame_size != 0) return error.InvalidSoundData;
        }

        fn play_internal(source: VoiceSource, pos: ?Vec3, opts: *const PlayOptions) PlayError!SoundHandle {
            switch (source) {
                .buffer => |buffer| {
                    if (buffers.get(buffer) == null) return error.InvalidSoundBuffer;
                },
                .stream => |stream| {
                    const resource = streams.get_ptr(stream) orelse return error.InvalidStreamingSound;
                    if (resource.active_voice != null) return error.StreamAlreadyPlaying;
                },
            }

            const vi = for (0..MAX_VOICES) |i| {
                if (voices[i] == null) break i;
            } else return error.TooManyVoices;

            const handle = make_handle(vi);

            voices[vi] = .{
                .source = source,
                .cursor = std.atomic.Value(usize).init(0),
                .position = pos,
                .volume = opts.volume,
                .priority = opts.priority,
                .ref_distance = opts.ref_distance,
                .max_distance = opts.max_distance,
                .slot = null,
                .handle = handle,
            };

            if (source == .stream) {
                streams.get_ptr(source.stream).?.active_voice = handle;
            }

            return handle;
        }

        fn slot_source(index: usize) ?SlotSource {
            const voice = &(voices[index] orelse return null);
            return switch (voice.source) {
                .buffer => |handle| blk: {
                    const buffer = buffers.get(handle) orelse return null;
                    break :blk .{ .buffer = .{
                        .format = buffer.format,
                        .pcm = buffer.pcm,
                        .cursor = &voice.cursor,
                    } };
                },
                .stream => |handle| blk: {
                    const stream = streams.get(handle) orelse return null;
                    break :blk .{ .stream = .{
                        .reader = stream.reader,
                        .format = stream.format,
                        .byte_length = stream.byte_length,
                    } };
                },
            };
        }

        fn stop_voices_for_buffer(handle: SoundBufferHandle) void {
            for (0..MAX_VOICES) |i| {
                if (voices[i]) |voice| {
                    if (voice.source == .buffer and voice.source.buffer == handle) {
                        if (voice.slot) |s| Backend.stop_slot(s);
                        release_voice(i);
                    }
                }
            }
        }

        fn find_index(handle: SoundHandle) ?usize {
            const raw = handle.raw_index();
            if (raw == 0 or raw > MAX_VOICES) return null;
            const i = raw - 1;
            if (voice_generations[i] != handle.generation) return null;
            if (voices[i] != null and voices[i].?.handle == handle) return i;
            return null;
        }

        fn make_handle(index: usize) SoundHandle {
            return SoundHandle.from_index(index + 1, voice_generations[index]);
        }

        fn release_voice(index: usize) void {
            if (voices[index]) |voice| {
                if (voice.source == .stream) {
                    if (streams.get_ptr(voice.source.stream)) |stream| {
                        if (stream.active_voice == voice.handle) stream.active_voice = null;
                    }
                }
            }
            voices[index] = null;
            voice_generations[index] +%= 1;
            if (voice_generations[index] == 0) voice_generations[index] = 1;
        }

        fn find_free_slot(used: *const [MAX_SLOTS]bool, limit: usize) ?u8 {
            for (0..limit) |i| {
                if (!used[i]) return @intCast(i);
            }
            return null;
        }

        fn effective_score(voice: VirtualVoice) f32 {
            // Non-positional and critical always win.
            if (voice.position == null or voice.priority == .critical)
                return std.math.inf(f32);

            const to_source = Vec3.sub(voice.position.?, listener_pos);
            const dist = to_source.length();
            if (dist >= voice.max_distance) return 0;

            const atten = compute_attenuation(dist, voice.ref_distance, voice.max_distance);
            const weight: f32 = switch (voice.priority) {
                .low => 0.5,
                .normal => 1.0,
                .high => 2.0,
                .critical => unreachable,
            };
            return voice.volume * atten * weight;
        }

        /// Inverse-distance clamped attenuation.
        fn compute_attenuation(dist: f32, ref_dist: f32, max_dist: f32) f32 {
            const d = std.math.clamp(dist, ref_dist, max_dist);
            if (d <= ref_dist) return 1.0;
            return ref_dist / (ref_dist + (d - ref_dist));
        }

        const GainPan = struct { gain: f32, pan: f32 };

        fn compute_gain_pan(voice: VirtualVoice) GainPan {
            if (voice.position == null) {
                return .{ .gain = voice.volume, .pan = 0 };
            }

            const pos = voice.position.?;
            const to_source = Vec3.sub(pos, listener_pos);
            const dist = to_source.length();
            const gain = voice.volume * compute_attenuation(dist, voice.ref_distance, voice.max_distance);

            // Stereo pan: project direction onto listener's right vector.
            var pan: f32 = 0;
            if (dist > 0.001) {
                const right = Vec3.cross(listener_fwd, listener_up).normalize();
                const dir = to_source.scale(1.0 / dist);
                pan = std.math.clamp(Vec3.dot(dir, right), -1.0, 1.0);
            }

            return .{ .gain = gain, .pan = pan };
        }
    };
}

test "mixer buffer playback and destroy stop voices" {
    const Backend = struct {
        var active: [2]bool = @splat(false);
        var last_source: ?SlotSource = null;

        pub fn setup(_: std.mem.Allocator, _: std.Io) void {}
        pub fn init() @import("../platform/audio_api.zig").InitError!void {
            active = @splat(false);
            last_source = null;
        }
        pub fn deinit() void {}
        pub fn update() void {}
        pub fn max_voices() u32 {
            return active.len;
        }
        pub fn play_slot(slot: u8, source: SlotSource) @import("../platform/audio_api.zig").PlaySlotError!void {
            active[slot] = true;
            last_source = source;
        }
        pub fn stop_slot(slot: u8) void {
            active[slot] = false;
        }
        pub fn set_slot_gain_pan(_: u8, _: f32, _: f32) void {}
        pub fn is_slot_active(slot: u8) bool {
            return active[slot];
        }
    };

    const Mix = Mixer(Backend);
    try Mix.init();
    defer Mix.deinit();

    const pcm = [_]u8{ 0, 0, 1, 0 };
    const buffer = try Mix.create_buffer(&.{
        .format = .{ .sample_rate = 44_100, .channels = 1, .bit_depth = 16 },
        .pcm = &pcm,
    });

    const voice = try Mix.play_buffer(buffer, &.{});
    Mix.update();
    try std.testing.expect(Mix.is_playing(voice));
    try std.testing.expect(Backend.last_source != null);
    try std.testing.expectEqual(@as(usize, 0), Backend.last_source.?.buffer.cursor.load(.acquire));

    Mix.destroy_buffer(buffer);
    try std.testing.expect(!Mix.is_playing(voice));
    try std.testing.expect(!Backend.active[0]);
}

test "mixer rejects stale buffers and active stream replay" {
    const Backend = struct {
        pub fn setup(_: std.mem.Allocator, _: std.Io) void {}
        pub fn init() @import("../platform/audio_api.zig").InitError!void {}
        pub fn deinit() void {}
        pub fn update() void {}
        pub fn max_voices() u32 {
            return 1;
        }
        pub fn play_slot(_: u8, _: SlotSource) @import("../platform/audio_api.zig").PlaySlotError!void {}
        pub fn stop_slot(_: u8) void {}
        pub fn set_slot_gain_pan(_: u8, _: f32, _: f32) void {}
        pub fn is_slot_active(_: u8) bool {
            return true;
        }
    };

    const Mix = Mixer(Backend);
    try Mix.init();
    defer Mix.deinit();

    const pcm = [_]u8{ 0, 0 };
    const buffer = try Mix.create_buffer(&.{
        .format = .{ .sample_rate = 44_100, .channels = 1, .bit_depth = 16 },
        .pcm = &pcm,
    });
    Mix.destroy_buffer(buffer);
    try std.testing.expectError(error.InvalidSoundBuffer, Mix.play_buffer(buffer, &.{}));

    var reader = std.Io.Reader.fixed(&pcm);
    const stream = try Mix.create_stream(&.{
        .reader = &reader,
        .format = .{ .sample_rate = 44_100, .channels = 1, .bit_depth = 16 },
        .byte_length = pcm.len,
    });
    _ = try Mix.play_stream(stream, &.{});
    try std.testing.expectError(error.StreamAlreadyPlaying, Mix.play_stream(stream, &.{}));
}
