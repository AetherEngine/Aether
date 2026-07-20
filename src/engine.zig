const std = @import("std");
const assert = std.debug.assert;

const Util = @import("util/util.zig");
const memory = @import("util/memory.zig");
const logger = @import("util/logger.zig");
const Core = @import("core/core.zig");
const Platform = @import("platform/platform.zig");
const Rendering = @import("rendering/rendering.zig");
const options = @import("options");

pub const Pool = memory.Pool;
pub const MemoryConfig = memory.MemoryConfig;
pub const MemoryProfile = memory.MemoryProfile;
pub const MemoryDiagnostics = memory.MemoryDiagnostics;

// -- category tracker (wrapper allocator with per-category accounting) --------

pub const CategoryTracker = struct {
    inner: std.mem.Allocator,
    used: usize,
    budget: usize,
    high_water: usize,
    allocation_count: usize,
    last_failed_request: ?usize,
    name: []const u8,

    const vtab = std.mem.Allocator.VTable{
        .alloc = tracked_alloc,
        .resize = tracked_resize,
        .remap = tracked_remap,
        .free = tracked_free,
    };

    fn tracked_alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CategoryTracker = @ptrCast(@alignCast(ctx));
        if (len > self.budget -| self.used) {
            self.last_failed_request = len;
            return null;
        }
        const result = self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr) orelse {
            self.last_failed_request = len;
            return null;
        };
        self.used += len;
        self.high_water = @max(self.high_water, self.used);
        self.allocation_count += 1;
        self.last_failed_request = null;
        return result;
    }

    fn tracked_free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CategoryTracker = @ptrCast(@alignCast(ctx));
        self.inner.vtable.free(self.inner.ptr, buf, alignment, ret_addr);
        if (buf.len > self.used) {
            Util.engine_logger.err("memory tracker underflow in {s}: used={} free_len={} ptr=0x{x} ret=0x{x}", .{
                self.name,
                self.used,
                buf.len,
                @intFromPtr(buf.ptr),
                ret_addr,
            });
            logger.flush();
            self.used = 0;
            return;
        }
        self.used -= buf.len;
        if (self.allocation_count > 0) {
            self.allocation_count -= 1;
        } else {
            Util.engine_logger.err("memory tracker allocation count underflow in {s}: ptr=0x{x} ret=0x{x}", .{
                self.name,
                @intFromPtr(buf.ptr),
                ret_addr,
            });
            logger.flush();
        }
    }

    fn tracked_resize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CategoryTracker = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const grow = new_len - buf.len;
            if (grow > self.budget -| self.used) {
                self.last_failed_request = new_len;
                return false;
            }
        }
        const ok = self.inner.vtable.resize(self.inner.ptr, buf, alignment, new_len, ret_addr);
        if (ok) {
            if (new_len >= buf.len) {
                self.used += new_len - buf.len;
                self.high_water = @max(self.high_water, self.used);
            } else {
                self.used -= buf.len - new_len;
            }
            self.last_failed_request = null;
        } else {
            self.last_failed_request = new_len;
        }
        return ok;
    }

    fn tracked_remap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CategoryTracker = @ptrCast(@alignCast(ctx));
        if (new_len > buf.len) {
            const grow = new_len - buf.len;
            if (grow > self.budget -| self.used) {
                self.last_failed_request = new_len;
                return null;
            }
        }
        const result = self.inner.vtable.remap(self.inner.ptr, buf, alignment, new_len, ret_addr);
        if (result != null) {
            if (new_len >= buf.len) {
                self.used += new_len - buf.len;
                self.high_water = @max(self.high_water, self.used);
            } else {
                self.used -= buf.len - new_len;
            }
            self.last_failed_request = null;
        } else {
            self.last_failed_request = new_len;
        }
        return result;
    }

    fn get_allocator(self: *CategoryTracker) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtab };
    }
};

const TRACKER_COUNT = @typeInfo(Pool).@"enum".fields.len;

// -- engine -------------------------------------------------------------------

pub const Engine = struct {
    io: std.Io,
    pool: memory.PoolAlloc,
    trackers: [TRACKER_COUNT]CategoryTracker,
    frame_scratch: std.heap.ArenaAllocator,
    running: bool,
    vsync: bool,
    input: Core.InputSystem,
    states: Core.StateMachine,
    dirs: Core.paths.Dirs,
    debug_trace_loops: u8,
    debug_trace_loop_index: u32,
    current_memory_profile: ?[]const u8,
    run_loop: RunLoop,

    const RunLoop = struct {
        run_start_ns: i96 = 0,
        last_us: i64 = 0,
        update_accum: i64 = 0,
        tick_accum: i64 = 0,
        fps_count: u32 = 0,
        fps_window_end: i64 = std.time.us_per_s,
        initialized: bool = false,

        fn reset(self: *RunLoop, io: std.Io) void {
            var clock = std.Io.Clock.boot;
            self.* = .{
                .run_start_ns = clock.now(io).toNanoseconds(),
                .fps_window_end = std.time.us_per_s,
                .initialized = true,
            };
        }
    };

    pub const Config = struct {
        memory: MemoryConfig,
        memory_profile_name: ?[]const u8 = null,
        width: u32 = 1280,
        height: u32 = 720,
        title: [:0]const u8 = "Aether",
        fullscreen: bool = false,
        vsync: bool = true,
        resizable: bool = false,
        /// Leaf directory name under the per-user data root (e.g.
        /// `~/Library/Application Support/<app_name>/`). Defaults to
        /// `title` so single-word titles just work; override when the
        /// title contains characters you don't want in a filesystem path.
        app_name: ?[]const u8 = null,
    };

    /// Initializes the engine in place. `self` must live at a stable address
    /// for the lifetime of the program -- the allocators produced by
    /// `allocator(p)` each carry a pointer into `self.trackers`, so moving or
    /// copying an initialized `Engine` will leave those pointers dangling.
    ///
    /// `environ_map` comes from `std.process.Init.environ_map` and is used
    /// only during init to resolve platform-specific data directories
    /// (HOME/APPDATA/XDG_DATA_HOME). The engine does not retain a
    /// reference.
    pub fn init(
        self: *Engine,
        sys_io: std.Io,
        environ_map: *const std.process.Environ.Map,
        mem: []u8,
        config: *const Config,
        state: *const Core.State,
    ) !void {
        assert(config.memory.total() <= mem.len);

        self.io = sys_io;
        self.running = true;
        self.vsync = config.vsync;
        self.input = .{};
        self.states = .{};
        self.debug_trace_loops = 0;
        self.debug_trace_loop_index = 0;
        self.current_memory_profile = config.memory_profile_name;
        self.run_loop = .{};

        self.pool = memory.PoolAlloc.init(mem, "main");
        const inner = self.pool.allocator();

        inline for (std.meta.fields(Pool), 0..) |f, i| {
            self.trackers[i] = .{
                .inner = inner,
                .used = 0,
                .budget = @field(config.memory, f.name),
                .high_water = 0,
                .allocation_count = 0,
                .last_failed_request = null,
                .name = f.name,
            };
        }
        self.frame_scratch = std.heap.ArenaAllocator.init(self.tracker_allocator(.frame));
        errdefer self.frame_scratch.deinit();

        // Dirs must resolve BEFORE logger (which opens a log file in the
        // data dir) and BEFORE Platform.init (which may read resources).
        const app_name = config.app_name orelse config.title;
        self.dirs = try Core.paths.resolve(sys_io, environ_map, app_name);

        try logger.init(sys_io, self.dirs.data);

        self.input.init(self.allocator(.game)) catch |err| switch (err) {
            error.OutOfMemory => return error.InputInitOutOfMemory,
            else => return err,
        };
        errdefer self.input.deinit();

        Platform.init(self, config.width, config.height, config.title, config.fullscreen, config.vsync, config.resizable) catch |err| switch (err) {
            error.OutOfMemory => return error.PlatformInitOutOfMemory,
            else => return err,
        };
        errdefer Platform.deinit(self);

        Rendering.Texture.init_defaults(self.allocator(.render)) catch |err| switch (err) {
            error.OutOfMemory => return error.DefaultTexturesOutOfMemory,
            else => return err,
        };
        self.states.init(self, state) catch |err| switch (err) {
            error.OutOfMemory => return error.StateInitOutOfMemory,
            else => return err,
        };
        self.reset_frame_scratch();
    }

    pub fn deinit(self: *Engine) void {
        self.states.deinit(self);
        self.frame_scratch.deinit();
        Rendering.Texture.Default.deinit(self.allocator(.render));
        Platform.deinit(self);
        self.input.deinit();
        logger.deinit(self.io);
        self.dirs.close(self.io);
    }

    pub fn allocator(self: *Engine, p: Pool) std.mem.Allocator {
        if (p == .frame) return self.frame_allocator();
        return self.tracker_allocator(p);
    }

    pub fn frame_allocator(self: *Engine) std.mem.Allocator {
        return self.frame_scratch.allocator();
    }

    fn tracker_allocator(self: *Engine, p: Pool) std.mem.Allocator {
        return self.trackers[@intFromEnum(p)].get_allocator();
    }

    fn reset_frame_scratch(self: *Engine) void {
        _ = self.frame_scratch.reset(.free_all);
    }

    pub fn quit(self: *Engine) void {
        self.running = false;
    }

    pub fn transition(self: *Engine, state: *const Core.State) void {
        self.states.transition(state);
    }

    pub fn has_pending_transition(self: *const Engine) bool {
        return self.states.has_pending_transition();
    }

    pub fn last_transition_failure(self: *const Engine) ?anyerror {
        return self.states.last_transition_failure();
    }

    pub fn set_vsync(self: *Engine, v: bool) void {
        self.vsync = v;
        Platform.gfx.set_vsync(v);
    }

    pub fn trace_next_loops(self: *Engine, count: u8) void {
        self.debug_trace_loops = count;
        self.debug_trace_loop_index = 0;
    }

    pub fn pool_used(self: *const Engine, p: Pool) usize {
        return self.trackers[@intFromEnum(p)].used;
    }

    pub fn pool_budget(self: *const Engine, p: Pool) usize {
        return self.trackers[@intFromEnum(p)].budget;
    }

    pub fn pool_remaining(self: *const Engine, p: Pool) usize {
        return self.pool_budget(p) -| self.pool_used(p);
    }

    pub const MemoryError = error{
        BudgetBelowCurrentUsage,
        TotalBudgetExceedsBackingMemory,
    };

    pub fn pool_high_water(self: *const Engine, p: Pool) usize {
        return self.trackers[@intFromEnum(p)].high_water;
    }

    pub fn pool_allocation_count(self: *const Engine, p: Pool) usize {
        return self.trackers[@intFromEnum(p)].allocation_count;
    }

    pub fn pool_last_failed_request(self: *const Engine, p: Pool) ?usize {
        return self.trackers[@intFromEnum(p)].last_failed_request;
    }

    pub fn set_budget(self: *Engine, p: Pool, new_budget: usize) MemoryError!void {
        if (new_budget < self.pool_used(p)) return error.BudgetBelowCurrentUsage;
        self.trackers[@intFromEnum(p)].budget = new_budget;
    }

    pub fn apply_memory_profile(self: *Engine, profile: *const MemoryProfile) MemoryError!void {
        if (profile.budgets.total() > self.pool.budget) return error.TotalBudgetExceedsBackingMemory;

        inline for (std.meta.fields(Pool)) |f| {
            const p: Pool = @enumFromInt(f.value);
            const new_budget = @field(profile.budgets, f.name);
            if (new_budget < self.pool_used(p)) return error.BudgetBelowCurrentUsage;
        }

        inline for (std.meta.fields(Pool)) |f| {
            const p: Pool = @enumFromInt(f.value);
            self.trackers[@intFromEnum(p)].budget = @field(profile.budgets, f.name);
        }
        self.current_memory_profile = profile.name;
    }

    pub fn memory_diagnostics(self: *const Engine) MemoryDiagnostics {
        var pools: [memory.POOL_COUNT]memory.PoolDiagnostics = undefined;
        inline for (std.meta.fields(Pool), 0..) |f, i| {
            const tracker = self.trackers[i];
            pools[i] = .{
                .name = f.name,
                .used = tracker.used,
                .budget = tracker.budget,
                .remaining_budget = tracker.budget -| tracker.used,
                .high_water = tracker.high_water,
                .allocation_count = tracker.allocation_count,
                .last_failed_request = tracker.last_failed_request,
            };
        }
        return .{
            .profile_name = self.current_memory_profile,
            .pools = pools,
            .physical_used = self.pool.used,
            .physical_capacity = self.pool.capacity(),
            .physical_largest_free_run = self.pool.largest_free_run(),
            .total_budget = self.total_budget(),
        };
    }

    pub fn total_used(self: *const Engine) usize {
        var total: usize = 0;
        for (self.trackers) |tracker| total += tracker.used;
        return total;
    }

    pub fn total_budget(self: *const Engine) usize {
        var total: usize = 0;
        for (self.trackers) |tracker| total += tracker.budget;
        return total;
    }

    pub fn report(self: *const Engine) void {
        const diagnostics = self.memory_diagnostics();
        Util.engine_logger.info("--- memory pools ---", .{});
        if (diagnostics.profile_name) |name| {
            Util.engine_logger.info("  profile: {s}", .{name});
        }
        inline for (std.meta.fields(Pool), 0..) |_, i| {
            const diag = diagnostics.pools[i];
            const used = diag.used;
            const budget = diag.budget;
            if (used <= budget) {
                Util.engine_logger.info("  {s}: {}/{} bytes ({}/{} KiB, {} remaining, high={}, allocs={})", .{
                    diag.name,
                    used,
                    budget,
                    used / 1024,
                    budget / 1024,
                    diag.remaining_budget,
                    diag.high_water,
                    diag.allocation_count,
                });
            } else {
                Util.engine_logger.warn("  {s}: {}/{} bytes ({}/{} KiB, {} over budget, high={}, allocs={})", .{
                    diag.name,
                    used,
                    budget,
                    used / 1024,
                    budget / 1024,
                    used - budget,
                    diag.high_water,
                    diag.allocation_count,
                });
            }
            if (diag.last_failed_request) |bytes| {
                Util.engine_logger.warn("    last failed request: {} bytes", .{bytes});
            }
        }
        Util.engine_logger.info("  total budget: {}/{} bytes ({}/{} KiB)", .{
            self.total_used(),
            self.total_budget(),
            self.total_used() / 1024,
            self.total_budget() / 1024,
        });
        Util.engine_logger.info("  physical: used={} capacity={} largest_free_run={}", .{
            diagnostics.physical_used,
            diagnostics.physical_capacity,
            diagnostics.physical_largest_free_run,
        });
        Util.engine_logger.info("--------------------", .{});
    }

    pub fn beginRun(self: *Engine) void {
        self.reset_frame_scratch();
        self.run_loop.reset(self.io);
    }

    pub fn stepFrame(self: *Engine) !bool {
        if (!self.run_loop.initialized) self.beginRun();
        try self.stepFrameInternal(false);
        return self.running;
    }

    pub fn run(self: *Engine) !void {
        self.beginRun();
        while (self.running) {
            try self.stepFrameInternal(true);
        }
    }

    fn stepFrameInternal(self: *Engine, allow_sleep: bool) !void {
        defer self.reset_frame_scratch();

        const US_PER_S: u64 = std.time.us_per_s;
        const NS_PER_US: i64 = 1000;

        // Fixed-step rates -- handheld backends target 60 Hz displays.
        const UPDATES_HZ: u32 = if (options.config.platform == .psp) 60 else 144;
        const TICKS_HZ: u32 = 20;
        const UPDATE_US: u64 = US_PER_S / UPDATES_HZ;
        const TICK_US: u64 = US_PER_S / TICKS_HZ;
        const update_budget_ns: i64 = @as(i64, @intCast(UPDATE_US)) * NS_PER_US;

        var clock = std.Io.Clock.boot;
        const fps_window_us: i64 = @intCast(US_PER_S);

        const report_fps = options.config.gfx != .headless;

        const trace_loop = self.debug_trace_loops > 0;
        const trace_loop_index = self.debug_trace_loop_index + 1;
        if (trace_loop) {
            Util.engine_logger.info("trace: engine loop {d} begin update_us={d} tick_us={d}", .{
                trace_loop_index,
                UPDATE_US,
                TICK_US,
            });
        }

        var now_us = elapsedUsSince(self.run_loop.run_start_ns, clock.now(self.io).toNanoseconds());
        var frame_dt_us = saturatingSubI64(now_us, self.run_loop.last_us);

        if (frame_dt_us <= 0) {
            if (allow_sleep) {
                try std.Io.sleep(self.io, .fromNanoseconds(std.time.ns_per_ms), clock);
            }
            now_us = elapsedUsSince(self.run_loop.run_start_ns, clock.now(self.io).toNanoseconds());
            frame_dt_us = @max(0, saturatingSubI64(now_us, self.run_loop.last_us));
            if (frame_dt_us <= 0) {
                frame_dt_us = 1000;
            }
        }

        if (frame_dt_us > 500_000) frame_dt_us = 500_000;
        self.run_loop.last_us = now_us;

        self.run_loop.update_accum = saturatingAddI64(self.run_loop.update_accum, frame_dt_us);
        self.run_loop.tick_accum = saturatingAddI64(self.run_loop.tick_accum, frame_dt_us);
        if (trace_loop) {
            Util.engine_logger.info("trace: engine loop {d} time now_us={d} frame_dt_us={d} last_us={d} update_accum={d} tick_accum={d}", .{
                trace_loop_index,
                now_us,
                frame_dt_us,
                self.run_loop.last_us,
                self.run_loop.update_accum,
                self.run_loop.tick_accum,
            });
            Util.engine_logger.info("trace: engine loop {d} platform begin", .{trace_loop_index});
        }

        const platform_start_ns = clock.now(self.io).toNanoseconds();
        Platform.update(self);
        const platform_done_ns = clock.now(self.io).toNanoseconds();
        var pre_update_elapsed_ns = elapsedNsBetween(platform_start_ns, platform_done_ns);
        if (trace_loop) {
            Util.engine_logger.info("trace: engine loop {d} platform end running={}", .{ trace_loop_index, self.running });
        }
        if (!self.running) return;

        // ---- fixed-rate TICK steps (e.g., 20 Hz logic) ----
        var is_tick_frame = false;
        var tick_cost_ns: i64 = 0;
        const tick_us: i64 = @intCast(TICK_US);
        var tick_steps: u32 = 0;
        while (self.run_loop.tick_accum >= tick_us) {
            @branchHint(.unpredictable);
            is_tick_frame = true;
            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} tick {d} begin accum={d}", .{
                    trace_loop_index,
                    tick_steps + 1,
                    self.run_loop.tick_accum,
                });
            }
            const tick_start_ns = clock.now(self.io).toNanoseconds();
            try self.states.tick(self);
            try self.states.commit_pending(self);
            if (!self.running) return;
            const tick_end_ns = clock.now(self.io).toNanoseconds();
            tick_cost_ns = saturatingAddI64(tick_cost_ns, elapsedNsBetween(tick_start_ns, tick_end_ns));
            self.run_loop.tick_accum -= tick_us;
            tick_steps += 1;
            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} tick {d} end accum={d}", .{
                    trace_loop_index,
                    tick_steps,
                    self.run_loop.tick_accum,
                });
            }
        }

        // ---- fixed-rate UPDATE steps (simulation & interpolation) ----
        const UPDATE_DT_S: f32 = @as(f32, @floatFromInt(UPDATE_US)) / @as(f32, US_PER_S);
        var update_steps: u32 = 0;
        while (self.run_loop.update_accum >= UPDATE_US) {
            @branchHint(.unpredictable);

            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} input begin update_accum={d}", .{
                    trace_loop_index,
                    self.run_loop.update_accum,
                });
            }
            const input_start_ns = clock.now(self.io).toNanoseconds();
            Platform.input.update(&self.input);
            self.input.update();
            const input_done_ns = clock.now(self.io).toNanoseconds();
            const engine_elapsed_ns = saturatingAddI64(pre_update_elapsed_ns, elapsedNsBetween(input_start_ns, input_done_ns));
            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} input end running={}", .{ trace_loop_index, self.running });
            }
            if (!self.running) return;

            const budget = Util.BudgetContext{
                .phase_budget_ns = update_budget_ns,
                .engine_elapsed_ns = engine_elapsed_ns,
                .remaining_ns = update_budget_ns - engine_elapsed_ns,
                .is_tick_frame = is_tick_frame,
                .tick_cost_ns = tick_cost_ns,
                .safety_margin_ns = Util.BudgetContext.DEFAULT_SAFETY_MARGIN_NS,
            };

            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} update {d} begin dt_bits=0x{x}", .{
                    trace_loop_index,
                    update_steps + 1,
                    @as(u32, @bitCast(UPDATE_DT_S)),
                });
            }
            try self.states.update(self, UPDATE_DT_S, &budget);
            try self.states.commit_pending(self);
            if (!self.running) return;
            pre_update_elapsed_ns = 0;
            self.run_loop.update_accum -= UPDATE_US;
            update_steps += 1;
            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} update {d} end accum={d}", .{
                    trace_loop_index,
                    update_steps,
                    self.run_loop.update_accum,
                });
            }
        }

        // ---- render ASAP (uncapped when vsync == false) ----
        const frame_dt_s: f32 = @as(f32, @floatFromInt(frame_dt_us)) / @as(f32, US_PER_S);
        // Time until next update step is due.
        const slack_us: i64 = @as(i64, @intCast(UPDATE_US)) - @max(0, self.run_loop.update_accum);
        const draw_budget_ns: i64 = if (self.vsync)
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

        if (trace_loop) {
            Util.engine_logger.info("trace: engine loop {d} ui_update begin", .{trace_loop_index});
        }
        try self.states.ui_update(self, frame_dt_s, &draw_budget);
        try self.states.commit_pending(self);
        if (!self.running) return;
        if (trace_loop) {
            Util.engine_logger.info("trace: engine loop {d} ui_update end", .{trace_loop_index});
        }

        if (trace_loop) {
            Util.engine_logger.info("trace: engine loop {d} start_frame begin frame_dt_us={d}", .{
                trace_loop_index,
                frame_dt_us,
            });
        }
        const drew_frame = Platform.gfx.api.start_frame();
        Platform.gfx.frame_active = drew_frame;
        if (trace_loop) {
            Util.engine_logger.info("trace: engine loop {d} start_frame end drew={}", .{ trace_loop_index, drew_frame });
        }
        if (drew_frame) {
            defer Platform.gfx.frame_active = false;
            const draw_start_ns = clock.now(self.io).toNanoseconds();
            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} draw begin", .{trace_loop_index});
            }
            try self.states.draw(self, frame_dt_s, &draw_budget);
            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} draw end", .{trace_loop_index});
            }
            _ = draw_start_ns;
            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} end_frame begin", .{trace_loop_index});
            }
            Platform.gfx.api.end_frame();
            Platform.gfx.frame_active = false;
            try self.states.commit_pending(self);
            if (!self.running) return;
            if (trace_loop) {
                Util.engine_logger.info("trace: engine loop {d} end_frame end", .{trace_loop_index});
            }
        } else {
            @branchHint(.unlikely);
            Platform.gfx.frame_active = false;
            if (allow_sleep) {
                if (options.config.gfx == .headless) {
                    const next_update = @as(i64, @intCast(UPDATE_US)) - self.run_loop.update_accum;
                    const next_tick = @as(i64, @intCast(TICK_US)) - self.run_loop.tick_accum;
                    const sleep_us = @max(0, @min(next_update, next_tick));
                    if (sleep_us > 0) {
                        const sleep_ns = sleep_us * NS_PER_US;
                        try std.Io.sleep(self.io, .fromNanoseconds(@intCast(sleep_ns)), clock);
                    }
                } else if (options.config.platform != .psp) {
                    try std.Io.sleep(self.io, .fromNanoseconds(50 * std.time.ns_per_ms), clock);
                }
            }
        }
        if (trace_loop) {
            Util.engine_logger.info("trace: engine loop {d} end ticks={d} updates={d}", .{
                trace_loop_index,
                tick_steps,
                update_steps,
            });
            self.debug_trace_loop_index = trace_loop_index;
            self.debug_trace_loops -= 1;
        }

        // ---- FPS counting ----
        if (report_fps) {
            if (drew_frame) self.run_loop.fps_count += 1;
            const end_us = elapsedUsSince(self.run_loop.run_start_ns, clock.now(self.io).toNanoseconds());
            if (end_us >= self.run_loop.fps_window_end) {
                Util.engine_logger.info("FPS: {}", .{self.run_loop.fps_count});
                self.run_loop.fps_count = 0;
                self.run_loop.fps_window_end = saturatingAddI64(end_us, fps_window_us);
            }
        }
    }
};

test "frame scratch allocator resets tracked usage" {
    const frame_budget = 4096;
    var backing: [16 * 1024]u8 align(64) = undefined;
    var engine: Engine = undefined;

    engine.pool = memory.PoolAlloc.init(backing[0..], "test");
    const inner = engine.pool.allocator();

    const config = MemoryConfig{
        .render = 1024,
        .audio = 1024,
        .game = 1024,
        .frame = frame_budget,
        .user = 1024,
    };
    inline for (std.meta.fields(Pool), 0..) |f, i| {
        engine.trackers[i] = .{
            .inner = inner,
            .used = 0,
            .budget = @field(config, f.name),
            .high_water = 0,
            .allocation_count = 0,
            .last_failed_request = null,
            .name = f.name,
        };
    }
    engine.frame_scratch = std.heap.ArenaAllocator.init(engine.tracker_allocator(.frame));
    defer engine.frame_scratch.deinit();

    const alloc = engine.frame_allocator();
    _ = try alloc.alloc(u8, 256);
    try std.testing.expect(engine.pool_used(.frame) > 0);

    engine.reset_frame_scratch();
    try std.testing.expectEqual(@as(usize, 0), engine.pool_used(.frame));
    try std.testing.expect(engine.pool_high_water(.frame) > 0);
}

test "zero frame budget disables frame scratch allocations" {
    var backing: [16 * 1024]u8 align(64) = undefined;
    var engine: Engine = undefined;

    engine.pool = memory.PoolAlloc.init(backing[0..], "test");
    const inner = engine.pool.allocator();

    const config = MemoryConfig{
        .render = 1024,
        .audio = 1024,
        .game = 1024,
        .frame = 0,
        .user = 1024,
    };
    inline for (std.meta.fields(Pool), 0..) |f, i| {
        engine.trackers[i] = .{
            .inner = inner,
            .used = 0,
            .budget = @field(config, f.name),
            .high_water = 0,
            .allocation_count = 0,
            .last_failed_request = null,
            .name = f.name,
        };
    }
    engine.frame_scratch = std.heap.ArenaAllocator.init(engine.tracker_allocator(.frame));
    defer engine.frame_scratch.deinit();

    try std.testing.expectError(error.OutOfMemory, engine.frame_allocator().alloc(u8, 1));
    try std.testing.expectEqual(@as(usize, 0), engine.pool_used(.frame));
    try std.testing.expect(engine.pool_last_failed_request(.frame) != null);

    engine.reset_frame_scratch();
    try std.testing.expectEqual(@as(usize, 0), engine.pool_used(.frame));
}

fn elapsedNsBetween(start_ns: i96, end_ns: i96) i64 {
    return clampI96ToI64(end_ns - start_ns);
}

fn elapsedUsSince(start_ns: i96, end_ns: i96) i64 {
    return @divTrunc(elapsedNsBetween(start_ns, end_ns), std.time.ns_per_us);
}

fn saturatingAddI64(a: i64, b: i64) i64 {
    return clampI96ToI64(@as(i96, a) + @as(i96, b));
}

fn saturatingSubI64(a: i64, b: i64) i64 {
    return clampI96ToI64(@as(i96, a) - @as(i96, b));
}

fn clampI96ToI64(value: i96) i64 {
    const max: i96 = std.math.maxInt(i64);
    const min: i96 = std.math.minInt(i64);
    if (value > max) return std.math.maxInt(i64);
    if (value < min) return std.math.minInt(i64);
    return @intCast(value);
}
