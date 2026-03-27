const Util = @import("../util/util.zig");

ptr: *anyopaque,
tab: *const VTable,

const VTable = struct {
    init: *const fn (ctx: *anyopaque) anyerror!void,
    deinit: *const fn (ctx: *anyopaque) void,

    tick: *const fn (ctx: *anyopaque) anyerror!void,
    update: *const fn (ctx: *anyopaque, dt: f32, budget: *const Util.BudgetContext) anyerror!void,
    draw: *const fn (ctx: *anyopaque, dt: f32, budget: *const Util.BudgetContext) anyerror!void,
};

const Self = @This();

pub fn init(self: *const Self) anyerror!void {
    try self.tab.init(self.ptr);
}

pub fn deinit(self: *const Self) void {
    self.tab.deinit(self.ptr);
}

pub fn tick(self: *const Self) anyerror!void {
    try self.tab.tick(self.ptr);
}

pub fn update(self: *const Self, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    try self.tab.update(self.ptr, dt, budget);
}

pub fn draw(self: *const Self, dt: f32, budget: *const Util.BudgetContext) anyerror!void {
    try self.tab.draw(self.ptr, dt, budget);
}
