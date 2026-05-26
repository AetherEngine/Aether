const std = @import("std");

extern fn osGetTime() u64;
extern fn svcGetSystemTick() u64;
extern fn svcSleepThread(ns: i64) void;

const arm11_hz: u128 = 16_756_991 * 2 * 4 * 2;
const unix_epoch_from_1900_ms: i96 = 2_208_988_800 * std.time.ms_per_s;

pub fn now(clock: std.Io.Clock) std.Io.Timestamp {
    return switch (clock) {
        .real => .fromNanoseconds((@as(i96, @intCast(osGetTime())) - unix_epoch_from_1900_ms) * std.time.ns_per_ms),
        .awake, .boot => .fromNanoseconds(@intCast((@as(u128, svcGetSystemTick()) * std.time.ns_per_s) / arm11_hz)),
        else => std.debug.panic("3ds std.Io clock {s} is not implemented", .{@tagName(clock)}),
    };
}

pub fn clockResolution(clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return switch (clock) {
        .real => .fromMilliseconds(1),
        .awake, .boot => .fromNanoseconds(4),
        else => error.ClockUnavailable,
    };
}

pub fn sleep(timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const ns = timeoutNanoseconds(timeout);
    if (ns <= 0) return;
    svcSleepThread(clampNs(ns));
}

fn timeoutNanoseconds(timeout: std.Io.Timeout) i96 {
    return switch (timeout) {
        .none => 0,
        .duration => |duration| duration.raw.nanoseconds,
        .deadline => |deadline| deadline.raw.nanoseconds - now(deadline.clock).nanoseconds,
    };
}

fn clampNs(ns: i96) i64 {
    if (ns > std.math.maxInt(i64)) return std.math.maxInt(i64);
    return @intCast(ns);
}
