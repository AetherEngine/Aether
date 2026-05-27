const std = @import("std");

extern fn osGetTime() u64;
extern fn svcGetSystemTick() u64;
extern fn svcSleepThread(ns: i64) void;

const ns_per_ms: u64 = std.time.ns_per_ms;
const ns_per_s: u64 = std.time.ns_per_s;
const arm11_hz: u64 = 16_756_991 * 2 * 4 * 2;
const unix_epoch_from_1900_ms: u64 = 2_208_988_800 * std.time.ms_per_s;
const max_i64_ns: u64 = @intCast(std.math.maxInt(i64));

pub fn now(clock: std.Io.Clock) std.Io.Timestamp {
    return switch (clock) {
        .real => .fromNanoseconds(@intCast(realNanoseconds())),
        .awake, .boot => .fromNanoseconds(@intCast(tickNanoseconds(svcGetSystemTick()))),
        else => std.debug.panic("3ds std.Io clock {s} is not implemented", .{@tagName(clock)}),
    };
}

pub fn clockResolution(clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return switch (clock) {
        .real => .fromNanoseconds(std.time.ns_per_ms),
        .awake, .boot => .fromNanoseconds(4),
        else => error.ClockUnavailable,
    };
}

pub fn sleep(timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const ns = timeoutNanoseconds(timeout);
    if (ns <= 0) return;
    svcSleepThread(ns);
}

fn realNanoseconds() u64 {
    const ms_since_1900 = osGetTime();
    if (ms_since_1900 <= unix_epoch_from_1900_ms) return 0;
    return millisecondsToNanoseconds(ms_since_1900 - unix_epoch_from_1900_ms);
}

fn tickNanoseconds(ticks: u64) u64 {
    const seconds = ticks / arm11_hz;
    const remainder = ticks % arm11_hz;
    const whole_ns = secondsToNanoseconds(seconds);
    if (whole_ns == max_i64_ns) return max_i64_ns;

    const fractional_ns = (remainder *% ns_per_s) / arm11_hz;
    if (fractional_ns > max_i64_ns - whole_ns) return max_i64_ns;
    return whole_ns + fractional_ns;
}

fn millisecondsToNanoseconds(ms: u64) u64 {
    if (ms >= max_i64_ns / ns_per_ms) return max_i64_ns;
    return ms *% ns_per_ms;
}

fn secondsToNanoseconds(seconds: u64) u64 {
    if (seconds >= max_i64_ns / ns_per_s) return max_i64_ns;
    return seconds *% ns_per_s;
}

fn timeoutNanoseconds(timeout: std.Io.Timeout) i64 {
    return switch (timeout) {
        .none => 0,
        .duration => |duration| clampNs(duration.raw.nanoseconds),
        .deadline => |deadline| deadlineNanoseconds(deadline),
    };
}

fn clampNs(ns: i96) i64 {
    if (ns > std.math.maxInt(i64)) return std.math.maxInt(i64);
    if (ns < std.math.minInt(i64)) return std.math.minInt(i64);
    return @intCast(ns);
}

fn deadlineNanoseconds(deadline: std.Io.Clock.Timestamp) i64 {
    const target = clampNs(deadline.raw.nanoseconds);
    const current = clampNs(now(deadline.clock).nanoseconds);
    if (target <= current) return 0;
    return target - current;
}
