const std = @import("std");
const assert = std.debug.assert;

const State = @import("State.zig");
const Util = @import("../util/util.zig");
const logger = @import("../util/logger.zig");
const Engine = @import("../engine.zig").Engine;

var initialized: bool = false;
var has_current: bool = false;
var curr_state: State = undefined;
var pending_state: ?State = null;

pub fn init(engine: *Engine, state: *const State) anyerror!void {
    assert(!initialized);

    curr_state = state.*;
    try curr_state.init(engine);

    pending_state = null;
    has_current = true;
    initialized = true;
    assert(initialized);
}

pub fn deinit(engine: *Engine) void {
    if (!initialized) return;

    if (has_current) {
        curr_state.deinit(engine);
        has_current = false;
    }
    pending_state = null;
    initialized = false;
    assert(!initialized);
}

/// Queue a state replacement. The transition is committed by the engine loop
/// after the current tick/update/draw callback returns, never immediately
/// inside user state code.
pub fn transition(engine: *Engine, state: *const State) void {
    _ = engine;
    assert(initialized);
    pending_state = state.*;
}

pub fn has_pending_transition() bool {
    return pending_state != null;
}

pub fn commit_pending(engine: *Engine) anyerror!void {
    assert(initialized);

    const next = pending_state orelse return;
    pending_state = null;

    if (has_current and next.ptr == curr_state.ptr and next.tab == curr_state.tab) return;

    if (has_current) {
        curr_state.deinit(engine);
        has_current = false;
    }

    curr_state = next;
    curr_state.init(engine) catch |err| {
        Util.engine_logger.err("state transition failed during init: {s}; exiting", .{@errorName(err)});
        logger.flush();
        engine.quit();
        return err;
    };
    has_current = true;
}

pub fn tick(engine: *Engine) anyerror!void {
    assert(initialized);
    assert(has_current);
    try curr_state.tick(engine);
}

pub fn update(engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    assert(initialized);
    assert(has_current);
    try curr_state.update(engine, dt, budget);
}

pub fn draw(engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    assert(initialized);
    assert(has_current);
    try curr_state.draw(engine, dt, budget);
}

const TestStateData = struct {
    init_count: u32 = 0,
    deinit_count: u32 = 0,
    tick_count: u32 = 0,
    fail_init: bool = false,

    fn init(ctx: *anyopaque, _: *Engine) anyerror!void {
        const self: *TestStateData = @ptrCast(@alignCast(ctx));
        if (self.fail_init) return error.TestInitFailed;
        self.init_count += 1;
    }

    fn deinit(ctx: *anyopaque, _: *Engine) void {
        const self: *TestStateData = @ptrCast(@alignCast(ctx));
        self.deinit_count += 1;
    }

    fn tick(ctx: *anyopaque, _: *Engine) anyerror!void {
        const self: *TestStateData = @ptrCast(@alignCast(ctx));
        self.tick_count += 1;
    }

    fn update(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {}
    fn draw(_: *anyopaque, _: *Engine, _: f32, _: *const Util.BudgetContext) anyerror!void {}

    fn state(self: *TestStateData) State {
        return .{ .ptr = self, .tab = &.{
            .init = TestStateData.init,
            .deinit = TestStateData.deinit,
            .tick = TestStateData.tick,
            .update = TestStateData.update,
            .draw = TestStateData.draw,
        } };
    }
};

test "state transition is queued until engine commit point" {
    var engine: Engine = undefined;
    engine.running = true;

    var a = TestStateData{};
    var b = TestStateData{};
    const a_state = a.state();
    const b_state = b.state();

    try init(&engine, &a_state);
    defer deinit(&engine);

    try std.testing.expectEqual(@as(u32, 1), a.init_count);
    transition(&engine, &b_state);
    try std.testing.expect(has_pending_transition());
    try std.testing.expectEqual(@as(u32, 0), b.init_count);

    try tick(&engine);
    try std.testing.expectEqual(@as(u32, 1), a.tick_count);
    try std.testing.expectEqual(@as(u32, 0), b.tick_count);

    try commit_pending(&engine);
    try std.testing.expect(!has_pending_transition());
    try std.testing.expectEqual(@as(u32, 1), a.deinit_count);
    try std.testing.expectEqual(@as(u32, 1), b.init_count);
}

test "state transition init failure exits without deinit retry" {
    var engine: Engine = undefined;
    engine.running = true;

    var a = TestStateData{};
    var b = TestStateData{ .fail_init = true };
    const a_state = a.state();
    const b_state = b.state();

    try init(&engine, &a_state);
    defer deinit(&engine);

    transition(&engine, &b_state);
    try std.testing.expectError(error.TestInitFailed, commit_pending(&engine));
    try std.testing.expect(!engine.running);
    try std.testing.expectEqual(@as(u32, 1), a.deinit_count);
    try std.testing.expectEqual(@as(u32, 0), b.init_count);
}
