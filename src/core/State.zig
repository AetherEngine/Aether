const Util = @import("../util/util.zig");
const Engine = @import("../engine.zig").Engine;

ptr: *anyopaque,
tab: *const VTable,

const VTable = struct {
    init: *const fn (ctx: *anyopaque, engine: *Engine) anyerror!void,
    deinit: *const fn (ctx: *anyopaque, engine: *Engine) void,

    tick: *const fn (ctx: *anyopaque, engine: *Engine) anyerror!void,
    update: *const fn (ctx: *anyopaque, engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void,
    draw: *const fn (ctx: *anyopaque, engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void,
};

const Self = @This();

pub fn init(self: *const Self, engine: *Engine) anyerror!void {
    try self.tab.init(self.ptr, engine);
}

pub fn deinit(self: *const Self, engine: *Engine) void {
    self.tab.deinit(self.ptr, engine);
}

pub fn tick(self: *const Self, engine: *Engine) anyerror!void {
    try self.tab.tick(self.ptr, engine);
}

pub fn update(self: *const Self, engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    try self.tab.update(self.ptr, engine, dt, budget);
}

pub fn draw(self: *const Self, engine: *Engine, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    try self.tab.draw(self.ptr, engine, dt, budget);
}
