const std = @import("std");
const Core = @import("core/core.zig");
const Util = @import("util/util.zig");
const Platform = @import("platform/platform.zig");

pub var running = true;
var vsync = true;

pub const Config = struct {
    memory: Util.MemoryConfig,
    width: u32 = 1280,
    height: u32 = 720,
    title: [:0]const u8 = "Aether",
    fullscreen: bool = false,
    vsync: bool = true,
    resizable: bool = false,
};

pub fn init(io: std.Io, mem: []u8, config: Config, state: *const Core.State) !void {
    vsync = config.vsync;

    // Allocator is first
    try Util.init(io, mem, config.memory);
    try Platform.init(config.width, config.height, config.title, config.fullscreen, config.vsync, config.resizable);
    try Core.input.init(Util.allocator(.game));
    try Core.state_machine.init(state);
}

pub fn deinit() void {
    Core.state_machine.deinit();
    Core.input.deinit();

    Platform.deinit();

    // Allocator is last
    Util.deinit();
}

pub fn quit() void {
    running = false;
}

pub fn main_loop() !void {
    const io = Util.io();
    const US_PER_S: u64 = std.time.us_per_s;
    const NS_PER_US: i64 = 1000;

    const options = @import("options");
    // Fixed-step rates — PSP targets 60 Hz display
    const UPDATES_HZ: u32 = if (options.config.platform == .psp) 60 else 144;
    const TICKS_HZ: u32 = 20;
    const UPDATE_US: u64 = US_PER_S / UPDATES_HZ;
    const TICK_US: u64 = US_PER_S / TICKS_HZ;

    const update_budget_ns: i64 = @as(i64, @intCast(UPDATE_US)) * NS_PER_US;
    _ = TICK_US;

    var clock = std.Io.Clock.real;

    var last_us: i64 = @truncate(@divTrunc(clock.now(io).toNanoseconds(), 1000));
    var update_accum: i64 = 0;
    var tick_accum: i64 = 0;

    var fps_count: u32 = 0;
    var fps_window_end: i64 = last_us + US_PER_S;

    while (running) {
        const now_us: i64 = @truncate(@divTrunc(clock.now(io).toNanoseconds(), 1000));
        var frame_dt_us: i64 = now_us - last_us;
        last_us = now_us;

        if (frame_dt_us > 500_000) frame_dt_us = 500_000;

        update_accum += frame_dt_us;
        tick_accum += frame_dt_us;

        // ---- fixed-rate TICK steps (e.g., 20 Hz logic) ----
        var is_tick_frame = false;
        var tick_cost_ns: i64 = 0;
        const tick_us: i64 = @intCast(US_PER_S / TICKS_HZ);
        while (tick_accum >= tick_us) {
            @branchHint(.unpredictable);
            is_tick_frame = true;
            const tick_start_ns: i64 = @truncate(clock.now(io).toNanoseconds());
            try Core.state_machine.tick();
            const tick_end_ns: i64 = @truncate(clock.now(io).toNanoseconds());
            tick_cost_ns += tick_end_ns - tick_start_ns;
            tick_accum -= tick_us;
        }

        // ---- fixed-rate UPDATE steps (input update & interpolation) ----
        const UPDATE_DT_S: f32 = @as(f32, @floatFromInt(UPDATE_US)) / @as(f32, US_PER_S);
        while (update_accum >= UPDATE_US) {
            @branchHint(.unpredictable);

            const step_start_ns: i64 = @truncate(clock.now(io).toNanoseconds());
            Platform.update();
            Core.input.update();
            const engine_done_ns: i64 = @truncate(clock.now(io).toNanoseconds());
            const engine_elapsed_ns = engine_done_ns - step_start_ns;

            const budget = Util.BudgetContext{
                .phase_budget_ns = update_budget_ns,
                .engine_elapsed_ns = engine_elapsed_ns,
                .remaining_ns = update_budget_ns - engine_elapsed_ns,
                .is_tick_frame = is_tick_frame,
                .tick_cost_ns = tick_cost_ns,
                .safety_margin_ns = Util.BudgetContext.DEFAULT_SAFETY_MARGIN_NS,
            };

            try Core.state_machine.update(UPDATE_DT_S, &budget);
            update_accum -= UPDATE_US;
        }

        // ---- render ASAP (uncapped when vsync == false) ----
        const frame_dt_s: f32 = @as(f32, @floatFromInt(frame_dt_us)) / @as(f32, US_PER_S);
        if (Platform.gfx.api.start_frame()) {
            const draw_start_ns: i64 = @truncate(clock.now(io).toNanoseconds());
            // Time until next update step is due
            const slack_us: i64 = @as(i64, @intCast(UPDATE_US)) - @max(0, update_accum);
            const draw_budget_ns: i64 = if (vsync)
                slack_us * NS_PER_US
            else
                std.math.maxInt(i64);

            const draw_budget = Util.BudgetContext{
                .phase_budget_ns = draw_budget_ns,
                .engine_elapsed_ns = 0,
                .remaining_ns = draw_budget_ns,
                .is_tick_frame = is_tick_frame,
                .tick_cost_ns = tick_cost_ns,
                .safety_margin_ns = Util.BudgetContext.DEFAULT_SAFETY_MARGIN_NS,
            };

            try Core.state_machine.draw(frame_dt_s, &draw_budget);
            _ = draw_start_ns;
            Platform.gfx.api.end_frame();
        } else {
            @branchHint(.unlikely);
            try std.Io.sleep(io, .fromMilliseconds(50), clock);
        }

        // ---- FPS counting ----
        fps_count += 1;
        const end_us: i64 = @truncate(@divTrunc(clock.now(io).toNanoseconds(), 1000));
        if (end_us >= fps_window_end) {
            Util.engine_logger.info("FPS: {}", .{fps_count});
            fps_count = 0;
            fps_window_end = end_us + US_PER_S;
        }
    }
}
