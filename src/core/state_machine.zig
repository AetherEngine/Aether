const std = @import("std");
const assert = std.debug.assert;

const State = @import("State.zig");
const Util = @import("../util/util.zig");
const Engine = @import("../engine.zig").Engine;

var initialized: bool = false;
var curr_state: *const State = undefined;

pub fn init(engine: *Engine, state: *const State) anyerror!void {
    assert(!initialized);

    curr_state = state;
    try curr_state.init(engine);

    initialized = true;
    assert(initialized);
}

pub fn deinit(engine: *Engine) void {
    assert(initialized);

    curr_state.deinit(engine);

    initialized = false;
    assert(!initialized);
}

pub fn transition(engine: *Engine, state: *const State) anyerror!void {
    assert(initialized);

    curr_state.deinit(engine);
    curr_state = state;
    try curr_state.init(engine);
}

pub fn tick(engine: *Engine) anyerror!void {
    assert(initialized);
    try curr_state.tick(engine);
}

pub fn update(engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    assert(initialized);
    try curr_state.update(engine, dt, budget);
}

pub fn draw(engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    assert(initialized);
    try curr_state.draw(engine, dt, budget);
}
