const std = @import("std");
const math = @import("platform").math;
const assert = std.debug.assert;

/// Every sound is rendered at 44.1 kHz, the rate most audio backends play at; not all of them resample.
pub const rate = 44_100;
/// Most tones one sound can layer.
pub const max_tones = 40;

pub const Wave = enum {
    /// Hollow and reedy; the duty cycle sets how thin.
    square,
    /// Soft and round, in 16 steps like the NES's.
    triangle,
    /// Bright and brassy.
    saw,
    /// Pure, for bells and beeps.
    sine,
    /// Hiss, from a 15-bit shift register clocked at the tone's pitch: high for a hiss, low for a rumble.
    noise,
    /// The shift register's short loop: a buzzing, metallic rasp.
    metal,
};

pub const Tone = struct {
    wave: Wave = .square,
    /// For a square wave, the fraction of each cycle spent high: 0.5 is
    /// hollow, 0.125 thin and nasal.
    duty: f32 = 0.5,
    /// Pitch in Hz as it starts...
    hz: f32,
    /// ...and as it ends, sliding evenly in pitch between. Null holds it.
    to_hz: ?f32 = null,
    /// Seconds into the sound before it starts.
    at: f32 = 0,
    /// Seconds to swell to full volume, stay there, and die away.
    attack: f32 = 0.002,
    hold: f32 = 0,
    decay: f32 = 0.1,
    volume: f32 = 0.5,
    /// Pitch wobble, as a fraction of the pitch, and how fast, in Hz.
    vibrato: f32 = 0,
    vibrato_hz: f32 = 6,
    /// Volume wobble, from 0 (none) to 1 (all the way down), and how fast.
    tremolo: f32 = 0,
    tremolo_hz: f32 = 10,

    /// Seconds into the sound when it's died away.
    pub fn end(self: Tone) f32 {
        return self.at + self.attack + self.hold + self.decay;
    }

    /// This tone, `at` seconds in, at MIDI note `midi`. A slide keeps its
    /// interval.
    pub fn play(self: Tone, at: f32, midi: f32) Tone {
        var t = self;
        t.at = at;
        t.hz = note(midi);
        if (self.to_hz) |to| t.to_hz = to / self.hz * t.hz;
        return t;
    }

    /// This tone shifted `seconds` later and scaled to `volume`.
    pub fn echo(self: Tone, seconds: f32, volume: f32) Tone {
        var t = self;
        t.at += seconds;
        t.volume *= volume;
        return t;
    }
};

pub const Sound = struct {
    tones: []const Tone,
    /// Holds each output sample this many samples, lowering the rate for a grittier, older sound. 1 leaves it clean.
    crush: u8 = 1,
    /// Volume steps the output is rounded to, like a 4-bit DAC's 16. 0 leaves it smooth; otherwise at least 2.
    levels: u16 = 0,
    gain: f32 = 1,
};

/// Pitch in Hz of MIDI note `n`: 60 is middle C, 69 the A above it.
pub fn note(n: f32) f32 {
    return 440 * std.math.exp2((n - 69) / 12);
}

/// How many samples `sound` renders to; it takes two bytes each.
pub fn length(sound: Sound) usize {
    var longest: f32 = 0;
    for (sound.tones) |t| longest = math.max(longest, t.end());
    return @intFromFloat(math.ceil(longest * rate));
}

/// One tone as it plays out, sample by sample.
const Voice = struct {
    tone: Tone,
    /// Samples into the sound it starts and ends.
    start: usize,
    end: usize,
    attack: f32,
    hold: f32,
    decay: f32,
    /// Its pitch right now, and what that's multiplied by each sample.
    hz: f32,
    slide: f32,
    /// Cycles through the wave, and through each wobble, from 0 to 1.
    phase: f32 = 0,
    vibrato_phase: f32 = 0,
    tremolo_phase: f32 = 0,
    lfsr: u16,

    fn init(tone: Tone, seed: u16) Voice {
        const attack = tone.attack * rate;
        const hold = tone.hold * rate;
        const decay = tone.decay * rate;
        const start: usize = @intFromFloat(tone.at * rate);
        const span = math.max(1, attack + hold + decay);
        const to = tone.to_hz orelse tone.hz;
        return .{
            .tone = tone,
            .start = start,
            .end = start + @as(usize, @intFromFloat(math.ceil(span))),
            .attack = math.max(1, attack),
            .hold = hold,
            .decay = math.max(1, decay),
            .hz = tone.hz,
            .slide = std.math.pow(f32, to / tone.hz, 1 / span),
            .lfsr = seed,
        };
    }

    /// The next sample, from -1 to 1 at full volume.
    fn next(self: *Voice, i: usize) f32 {
        const t = self.tone;
        const local: f32 = @floatFromInt(i - self.start);

        var env: f32 = if (local < self.attack)
            local / self.attack
        else if (local < self.attack + self.hold)
            1
        else blk: {
            const d = 1 - math.min(1, (local - self.attack - self.hold) / self.decay);
            break :blk d * d;
        };
        if (t.tremolo > 0) {
            env *= 1 - t.tremolo * (0.5 + 0.5 * sine(self.tremolo_phase));
            self.tremolo_phase = wrap(self.tremolo_phase + t.tremolo_hz / rate);
        }

        var hz = self.hz;
        if (t.vibrato > 0) {
            hz *= 1 + t.vibrato * sine(self.vibrato_phase);
            self.vibrato_phase = wrap(self.vibrato_phase + t.vibrato_hz / rate);
        }
        self.hz *= self.slide;

        const p = self.phase;
        const s: f32 = switch (t.wave) {
            .square => if (p < t.duty) 1 else -1,
            .triangle => math.round((1 - 4 * @abs(p - 0.5)) * 7.5) / 7.5,
            .saw => 2 * p - 1,
            .sine => sine(p),
            .noise, .metal => if (self.lfsr & 1 == 0) 1 else -1,
        };

        self.phase += hz / rate;
        switch (t.wave) {
            .noise, .metal => while (self.phase >= 1) {
                self.phase -= 1;
                self.clock();
            },
            else => self.phase = wrap(self.phase),
        }
        return s * env * t.volume;
    }

    /// Steps the shift register, as the NES's noise channel does.
    fn clock(self: *Voice) void {
        const tap: u4 = if (self.tone.wave == .metal) 6 else 1;
        const bit = (self.lfsr ^ (self.lfsr >> tap)) & 1;
        self.lfsr = (self.lfsr >> 1) | (bit << 14);
    }
};

/// Renders `sound` into `out` as little-endian 16-bit PCM, two bytes a sample for `length(sound)` samples.
pub fn render(sound: Sound, out: []u8) void {
    assert(out.len == length(sound) * 2);
    assert(sound.tones.len <= max_tones);

    var voices: [max_tones]Voice = undefined;
    for (sound.tones, 0..) |tone, i| {
        // Each noise tone its own seed, so layered ones don't cancel out
        const seed: u16 = @intCast((1 + i * 0x2d1b) & 0x7fff);
        voices[i] = .init(tone, seed | 1);
    }
    const playing = voices[0..sound.tones.len];

    const steps = @as(f32, @floatFromInt(sound.levels)) / 2;
    var held: i16 = 0;
    for (0..out.len / 2) |i| {
        var mix: f32 = 0;
        for (playing) |*v| {
            if (i >= v.start and i < v.end) mix += v.next(i);
        }
        mix = math.clamp(mix * sound.gain, -1, 1);
        if (sound.levels > 0) mix = math.round(mix * steps) / steps;

        if (i % math.max(1, sound.crush) == 0) held = @intFromFloat(mix * 32767);
        std.mem.writeInt(i16, out[i * 2 ..][0..2], held, .little);
    }
}

/// Sine of a phase in cycles, near enough for sound: a parabola per half cycle, bent closer to the curve.
fn sine(phase: f32) f32 {
    const x = wrap(phase);
    const half = if (x < 0.5) x * 2 else x * 2 - 1;
    const y = 4 * half * (1 - half);
    const curved = 0.775 * y + 0.225 * y * y;
    return if (x < 0.5) curved else -curved;
}

fn wrap(phase: f32) f32 {
    return phase - math.floor(phase);
}
