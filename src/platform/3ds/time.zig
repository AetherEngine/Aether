const std = @import("std");

extern fn osGetTime() u64;
extern fn svcSleepThread(ns: i64) void;

const ns_per_ms: u64 = std.time.ns_per_ms;
const max_i64_ns: i64 = std.math.maxInt(i64);

pub fn now(clock: std.Io.Clock) std.Io.Timestamp {
    switch (clock) {
        .real, .awake, .boot => return .fromNanoseconds(osTimeNanoseconds(osGetTime())),
        else => std.debug.panic("3ds std.Io clock {s} is not implemented", .{@tagName(clock)}),
    }
}

pub fn clockResolution(clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    switch (clock) {
        .real, .awake, .boot => return .fromNanoseconds(ns_per_ms),
        else => return error.ClockUnavailable,
    }
}

fn osTimeNanoseconds(ms: u64) i64 {
    const ns = @as(u128, ms) * ns_per_ms;
    return @intCast(@min(ns, @as(u128, @intCast(max_i64_ns))));
}

pub fn sleep(timeout: std.Io.Timeout) std.Io.Cancelable!void {
    const ns = timeoutNanoseconds(timeout);
    if (ns <= 0) return;
    svcSleepThread(ns);
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
