const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

const State = @import("State.zig");
const Util = @import("../util/util.zig");
const logger = @import("../util/logger.zig");
const Engine = @import("../engine.zig").Engine;

pub const StateMachine = struct {
    pub const TransitionError = error{
        StateTransitionFailed,
    };

    initialized: bool = false,
    has_current: bool = false,
    curr_state: State = undefined,
    pending_state: ?State = null,
    last_transition_error: ?anyerror = null,

    pub fn init(self: *StateMachine, engine: *Engine, state: *const State) anyerror!void {
        assert(!self.initialized);

        self.curr_state = state.*;
        try self.curr_state.init(engine);

        self.pending_state = null;
        self.last_transition_error = null;
        self.has_current = true;
        self.initialized = true;
        assert(self.initialized);
    }

    pub fn deinit(self: *StateMachine, engine: *Engine) void {
        if (!self.initialized) return;

        if (self.has_current) {
            self.curr_state.deinit(engine);
            self.has_current = false;
        }
        self.pending_state = null;
        self.last_transition_error = null;
        self.initialized = false;
        assert(!self.initialized);
    }

    /// Queue a state replacement. The transition is committed by the engine
    /// loop after the current tick/update/draw callback returns, never
    /// immediately inside user state code.
    pub fn transition(self: *StateMachine, state: *const State) void {
        assert(self.initialized);
        self.pending_state = state.*;
    }

    pub fn has_pending_transition(self: *const StateMachine) bool {
        return self.pending_state != null;
    }

    /// Returns the original error from the most recent failed replacement
    /// state's `init`, if a queued transition failed during commit.
    pub fn last_transition_failure(self: *const StateMachine) ?anyerror {
        return self.last_transition_error;
    }

    pub fn commit_pending(self: *StateMachine, engine: *Engine) TransitionError!void {
        assert(self.initialized);

        const next = self.pending_state orelse return;
        self.pending_state = null;

        if (self.has_current and next.ptr == self.curr_state.ptr and next.tab == self.curr_state.tab) return;

        if (self.has_current) {
            self.curr_state.deinit(engine);
            self.has_current = false;
        }

        self.curr_state = next;
        self.curr_state.init(engine) catch |err| {
            self.last_transition_error = err;
            if (!builtin.is_test) {
                Util.engine_logger.err("state transition failed during init: {s}; exiting", .{@errorName(err)});
            }
            logger.flush();
            engine.quit();
            return error.StateTransitionFailed;
        };
        self.last_transition_error = null;
        self.has_current = true;
    }

    pub fn tick(self: *StateMachine, engine: *Engine) anyerror!void {
        assert(self.initialized);
        assert(self.has_current);
        try self.curr_state.tick(engine);
    }

    pub fn update(self: *StateMachine, engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
        assert(self.initialized);
        assert(self.has_current);
        try self.curr_state.update(engine, dt, budget);
    }

    pub fn draw(self: *StateMachine, engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
        assert(self.initialized);
        assert(self.has_current);
        try self.curr_state.draw(engine, dt, budget);
    }
};

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
    var states = StateMachine{};

    var a = TestStateData{};
    var b = TestStateData{};
    const a_state = a.state();
    const b_state = b.state();

    try states.init(&engine, &a_state);
    defer states.deinit(&engine);

    try std.testing.expectEqual(@as(u32, 1), a.init_count);
    states.transition(&b_state);
    try std.testing.expect(states.has_pending_transition());
    try std.testing.expectEqual(@as(u32, 0), b.init_count);

    try states.tick(&engine);
    try std.testing.expectEqual(@as(u32, 1), a.tick_count);
    try std.testing.expectEqual(@as(u32, 0), b.tick_count);

    try states.commit_pending(&engine);
    try std.testing.expect(!states.has_pending_transition());
    try std.testing.expectEqual(@as(u32, 1), a.deinit_count);
    try std.testing.expectEqual(@as(u32, 1), b.init_count);
}

test "state transition init failure exits without deinit retry" {
    var engine: Engine = undefined;
    engine.running = true;
    var states = StateMachine{};

    var a = TestStateData{};
    var b = TestStateData{ .fail_init = true };
    const a_state = a.state();
    const b_state = b.state();

    try states.init(&engine, &a_state);
    defer states.deinit(&engine);

    states.transition(&b_state);
    try std.testing.expectError(error.StateTransitionFailed, states.commit_pending(&engine));
    try std.testing.expectEqual(error.TestInitFailed, states.last_transition_failure().?);
    try std.testing.expect(!engine.running);
    try std.testing.expectEqual(@as(u32, 1), a.deinit_count);
    try std.testing.expectEqual(@as(u32, 0), b.init_count);
}

test "state machines keep pending transitions independent" {
    var engine: Engine = undefined;
    engine.running = true;
    var first = StateMachine{};
    var second = StateMachine{};

    var a = TestStateData{};
    var b = TestStateData{};
    var c = TestStateData{};
    const a_state = a.state();
    const b_state = b.state();
    const c_state = c.state();

    try first.init(&engine, &a_state);
    defer first.deinit(&engine);
    try second.init(&engine, &b_state);
    defer second.deinit(&engine);

    first.transition(&c_state);
    try std.testing.expect(first.has_pending_transition());
    try std.testing.expect(!second.has_pending_transition());
}
