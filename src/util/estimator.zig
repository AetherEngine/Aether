const std = @import("std");
const Util = @import("util.zig");

pub const Confidence = enum { p50, p75, p95, max };

pub const Estimator = struct {
    const CAPACITY: usize = 64;

    samples: [CAPACITY]i64,
    sorted: [CAPACITY]i64,
    head: usize,
    count: usize,
    start_ns: i64,

    cached_avg: i64,
    cached_min: i64,
    cached_max: i64,

    pub fn init() Estimator {
        return .{
            .samples = @splat(0),
            .sorted = @splat(0),
            .head = 0,
            .count = 0,
            .start_ns = 0,
            .cached_avg = 0,
            .cached_min = 0,
            .cached_max = 0,
        };
    }

    pub fn begin(self: *Estimator, io: std.Io) void {
        var clock = std.Io.Clock.real;
        self.start_ns = @truncate(clock.now(io).toNanoseconds());
    }

    pub fn end(self: *Estimator, io: std.Io) void {
        var clock = std.Io.Clock.real;
        const now_ns: i64 = @truncate(clock.now(io).toNanoseconds());
        const elapsed = now_ns - self.start_ns;
        self.start_ns = 0;
        self.record(elapsed);
    }

    pub fn record(self: *Estimator, elapsed_ns: i64) void {
        self.samples[self.head] = elapsed_ns;
        self.head = (self.head + 1) % CAPACITY;
        if (self.count < CAPACITY) self.count += 1;

        // Rebuild sorted array from valid samples
        const n = self.count;
        @memcpy(self.sorted[0..n], self.samples[0..n]);
        std.sort.insertion(i64, self.sorted[0..n], {}, std.sort.asc(i64));

        // Recompute cached stats
        var sum: i64 = 0;
        for (self.sorted[0..n]) |s| sum += s;
        self.cached_avg = @divTrunc(sum, @as(i64, @intCast(n)));
        self.cached_min = self.sorted[0];
        self.cached_max = self.sorted[n - 1];
    }

    pub fn estimate_cost(self: *const Estimator, confidence: Confidence) i64 {
        if (self.count == 0) return 0;
        const n = self.count;
        return switch (confidence) {
            .p50 => self.sorted[n / 2],
            .p75 => self.sorted[n * 3 / 4],
            .p95 => self.sorted[n * 95 / 100],
            .max => self.sorted[n - 1],
        };
    }

    pub fn fit_in(self: *const Estimator, available_ns: i64, confidence: Confidence) usize {
        const cost = self.estimate_cost(confidence);
        if (cost <= 0) return 1;
        if (available_ns <= 0) return 1;
        return @max(1, @as(usize, @intCast(@divFloor(available_ns, cost))));
    }

    pub fn is_warming_up(self: *const Estimator) bool {
        return self.count < CAPACITY;
    }

    pub fn avg_ns(self: *const Estimator) i64 {
        return self.cached_avg;
    }

    pub fn min_ns(self: *const Estimator) i64 {
        return self.cached_min;
    }

    pub fn max_ns(self: *const Estimator) i64 {
        return self.cached_max;
    }

    pub fn report(self: *const Estimator, name: []const u8) void {
        const logger = Util.engine_logger;

        logger.info("--- estimator: {s} ---", .{name});

        if (self.count == 0) {
            logger.info("  no samples", .{});
        } else {
            if (self.is_warming_up()) {
                logger.info("  samples: {}/{} (warming up)", .{ self.count, CAPACITY });
            } else {
                logger.info("  samples: {}/{}", .{ self.count, CAPACITY });
            }

            const to_us = struct {
                fn f(ns: i64) i32 {
                    return @intCast(@divTrunc(ns, 1000));
                }
            }.f;
            logger.info("  avg: {} us | min: {} us | max: {} us", .{
                to_us(self.cached_avg),
                to_us(self.cached_min),
                to_us(self.cached_max),
            });
            logger.info("  p50: {} us | p75: {} us | p95: {} us", .{
                to_us(self.estimate_cost(.p50)),
                to_us(self.estimate_cost(.p75)),
                to_us(self.estimate_cost(.p95)),
            });
        }

        logger.info("----------------------------", .{});
    }
};
