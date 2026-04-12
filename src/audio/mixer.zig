const std = @import("std");
const Vec3 = @import("../math/math.zig").Vec3;
const stream_mod = @import("stream.zig");
const Stream = stream_mod.Stream;

pub const SoundHandle = u32;

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

/// Platform-independent voice scheduler. Manages a pool of virtual voices
/// and assigns the highest-priority ones to real backend slots each tick.
///
/// `Backend` must satisfy the slot-based audio_api.Interface.
pub fn Mixer(comptime Backend: type) type {
    return struct {
        pub const MAX_VOICES: usize = 64;
        const MAX_SLOTS: usize = 32;

        const VirtualVoice = struct {
            stream: Stream,
            position: ?Vec3,
            volume: f32,
            priority: Priority,
            ref_distance: f32,
            max_distance: f32,
            slot: ?u8,
            handle: SoundHandle,
        };

        var voices: [MAX_VOICES]?VirtualVoice = @splat(null);
        var next_handle: SoundHandle = 1;
        var listener_pos: Vec3 = Vec3.zero();
        var listener_fwd: Vec3 = Vec3.new(0, 0, -1);
        var listener_up: Vec3 = Vec3.new(0, 1, 0);

        // -- lifecycle -------------------------------------------------------

        pub fn init() !void {
            try Backend.init();
        }

        pub fn deinit() void {
            for (0..MAX_VOICES) |i| {
                if (voices[i] != null) {
                    if (voices[i].?.slot) |s| Backend.stop_slot(s);
                    voices[i] = null;
                }
            }
            Backend.deinit();
        }

        // -- listener --------------------------------------------------------

        pub fn set_listener(pos: Vec3, forward: Vec3, up: Vec3) void {
            listener_pos = pos;
            listener_fwd = forward;
            listener_up = up;
        }

        // -- voice control ---------------------------------------------------

        /// Play a non-positional sound (music, UI). Never distance-culled.
        pub fn play(stream: Stream, opts: PlayOptions) !SoundHandle {
            return play_internal(stream, null, opts);
        }

        /// Play a positional sound. Subject to attenuation and slot priority.
        pub fn play_at(stream: Stream, pos: Vec3, opts: PlayOptions) !SoundHandle {
            return play_internal(stream, pos, opts);
        }

        pub fn stop(handle: SoundHandle) void {
            if (find_index(handle)) |i| {
                if (voices[i].?.slot) |s| Backend.stop_slot(s);
                voices[i] = null;
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
                            voices[i] = null;
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

            // 3. Sort by score descending (insertion sort — count <= 64).
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
                    if (find_free_slot(&used, max_slots)) |s| {
                        Backend.play_slot(s, voices[vi].?.stream) catch continue;
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

        fn play_internal(stream: Stream, pos: ?Vec3, opts: PlayOptions) !SoundHandle {
            const vi = for (0..MAX_VOICES) |i| {
                if (voices[i] == null) break i;
            } else return error.TooManyVoices;

            const handle = next_handle;
            next_handle +%= 1;
            if (next_handle == 0) next_handle = 1;

            voices[vi] = .{
                .stream = stream,
                .position = pos,
                .volume = opts.volume,
                .priority = opts.priority,
                .ref_distance = opts.ref_distance,
                .max_distance = opts.max_distance,
                .slot = null,
                .handle = handle,
            };

            return handle;
        }

        fn find_index(handle: SoundHandle) ?usize {
            for (0..MAX_VOICES) |i| {
                if (voices[i] != null and voices[i].?.handle == handle) return i;
            }
            return null;
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
