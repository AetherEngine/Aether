const std = @import("std");

const Timespec = extern struct {
    tv_sec: i64,
    tv_nsec: c_long,
};

extern fn clock_gettime(clock_id: c_int, tp: *Timespec) c_int;
extern fn clock_getres(clock_id: c_int, res: *Timespec) c_int;
extern fn svcSleepThread(ns: i64) void;

const ns_per_s: u64 = std.time.ns_per_s;
const max_i64_ns: i64 = std.math.maxInt(i64);
const CLOCK_REALTIME: c_int = 1;
const CLOCK_MONOTONIC: c_int = 4;

pub fn now(clock: std.Io.Clock) std.Io.Timestamp {
    const id = clockId(clock) orelse std.debug.panic("3ds std.Io clock {s} is not implemented", .{@tagName(clock)});
    var ts: Timespec = undefined;
    if (clock_gettime(id, &ts) != 0) {
        std.debug.panic("3ds clock_gettime failed for std.Io clock {s}", .{@tagName(clock)});
    }
    return .fromNanoseconds(timespecNanoseconds(ts));
}

pub fn clockResolution(clock: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    const id = clockId(clock) orelse return error.ClockUnavailable;
    var ts: Timespec = undefined;
    if (clock_getres(id, &ts) != 0) return error.ClockUnavailable;
    return .fromNanoseconds(timespecNanoseconds(ts));
}

fn clockId(clock: std.Io.Clock) ?c_int {
    return switch (clock) {
        .real => CLOCK_REALTIME,
        // libctru's POSIX shim supports CLOCK_MONOTONIC for svcGetSystemTick.
        // CLOCK_BOOTTIME is declared by newlib but not implemented by libctru.
        .awake, .boot => CLOCK_MONOTONIC,
        else => null,
    };
}

fn timespecNanoseconds(ts: Timespec) i64 {
    if (ts.tv_sec <= 0) return @max(0, @as(i64, @intCast(ts.tv_nsec)));

    const sec: i64 = @intCast(@min(ts.tv_sec, @divTrunc(max_i64_ns, @as(i64, @intCast(ns_per_s)))));
    const whole_ns = sec * @as(i64, @intCast(ns_per_s));
    const fractional_ns: i64 = @max(0, @as(i64, @intCast(ts.tv_nsec)));

    if (fractional_ns > max_i64_ns - whole_ns) return max_i64_ns;
    return whole_ns + fractional_ns;
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
