const std = @import("std");
const c = @import("../nintendo_c.zig").c;

pub fn now(clock: std.Io.Clock) std.Io.Timestamp {
    return switch (clock) {
        .real, .awake, .boot => .fromNanoseconds(@intCast((@as(u128, c.svcGetSystemTick()) * 625) / 12)),
        else => std.debug.panic("switch std.Io clock {s} is not implemented", .{@tagName(clock)}),
    };
}

pub fn clockResolution(clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return switch (clock) {
        .real, .awake, .boot => .fromNanoseconds(53),
        else => error.ClockUnavailable,
    };
}

pub fn sleep(timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const ns = timeout_nanoseconds(timeout);
    if (ns <= 0) return;
    c.svcSleepThread(clamp_ns(ns));
}

fn timeout_nanoseconds(timeout: std.Io.Timeout) i96 {
    return switch (timeout) {
        .none => 0,
        .duration => |duration| duration.raw.nanoseconds,
        .deadline => |deadline| deadline.raw.nanoseconds - now(deadline.clock).nanoseconds,
    };
}

fn clamp_ns(ns: i96) i64 {
    if (ns > std.math.maxInt(i64)) return std.math.maxInt(i64);
    return @intCast(ns);
}
