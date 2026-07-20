const std = @import("std");
const layout = @import("layout.zig");

pub const RendererId = enum(u8) {
    app0 = 0,
    app1 = 1,
    app2 = 2,
    app3 = 3,
    app4 = 4,
    app5 = 5,
    app6 = 6,
    app7 = 7,
};

pub const ClipMode = enum(u8) {
    inherit,
    none,
    reject_bounds,
};

pub const MAX_PAYLOAD_BYTES: usize = 32;

pub const Command = struct {
    renderer: RendererId,
    bounds: layout.LogicalRect,
    layer: u8,
    clip: ClipMode = .inherit,
    sequence: u16 = 0,
    payload_len: u8 = 0,
    payload_align: u8 = 1,
    payload: [MAX_PAYLOAD_BYTES]u8 = [_]u8{0} ** MAX_PAYLOAD_BYTES,

    pub fn init(renderer: RendererId, bounds: layout.LogicalRect, layer: u8, clip: ClipMode, sequence: u16, value: anytype) Command {
        const T = @TypeOf(value);
        comptime {
            if (@sizeOf(T) > MAX_PAYLOAD_BYTES) {
                @compileError("custom UI payload exceeds MAX_PAYLOAD_BYTES");
            }
            if (@alignOf(T) > 16) {
                @compileError("custom UI payload alignment exceeds supported command storage");
            }
        }
        var cmd: Command = .{
            .renderer = renderer,
            .bounds = bounds,
            .layer = layer,
            .clip = clip,
            .sequence = sequence,
            .payload_len = @intCast(@sizeOf(T)),
            .payload_align = @intCast(@alignOf(T)),
        };
        const src = std.mem.asBytes(&value);
        @memcpy(cmd.payload[0..src.len], src);
        return cmd;
    }

    pub fn read(self: *const Command, comptime T: type) T {
        std.debug.assert(self.payload_len == @sizeOf(T));
        std.debug.assert(self.payload_align == @alignOf(T));
        return std.mem.bytesToValue(T, self.payload[0..@sizeOf(T)]);
    }
};

pub const Renderer = struct {
    ctx: *anyopaque,
    reset: *const fn (ctx: *anyopaque) void,
    prepare: *const fn (ctx: *anyopaque, commands: []const Command) anyerror!void,
    draw: *const fn (ctx: *anyopaque, commands: []const Command) void,
};

pub const Registry = struct {
    renderers: [@typeInfo(RendererId).@"enum".fields.len]?Renderer = [_]?Renderer{null} ** @typeInfo(RendererId).@"enum".fields.len,

    pub fn register(self: *Registry, id: RendererId, renderer: Renderer) void {
        self.renderers[@intFromEnum(id)] = renderer;
    }

    pub fn get(self: *const Registry, id: RendererId) ?Renderer {
        return self.renderers[@intFromEnum(id)];
    }

    pub fn reset_all(self: *const Registry) void {
        for (self.renderers) |entry| {
            if (entry) |renderer| renderer.reset(renderer.ctx);
        }
    }

    pub fn prepare_all(self: *const Registry, commands: []const Command) !void {
        for (self.renderers, 0..) |entry, i| {
            const renderer = entry orelse continue;
            const id: RendererId = @enumFromInt(i);
            var first: usize = 0;
            while (first < commands.len) {
                while (first < commands.len and commands[first].renderer != id) : (first += 1) {}
                if (first == commands.len) break;
                var end = first + 1;
                while (end < commands.len and commands[end].renderer == id) : (end += 1) {}
                try renderer.prepare(renderer.ctx, commands[first..end]);
                first = end;
            }
        }
    }

    pub fn draw_group(self: *const Registry, commands: []const Command) void {
        if (commands.len == 0) return;
        const renderer = self.get(commands[0].renderer) orelse return;
        renderer.draw(renderer.ctx, commands);
    }
};

test "custom command stores copied payload" {
    const Payload = extern struct { a: u16, b: f32 };
    const p = Payload{ .a = 7, .b = 3.5 };
    const cmd = Command.init(.app0, .{ .x0 = 1, .y0 = 2, .x1 = 3, .y1 = 4 }, 9, .inherit, 11, p);
    try std.testing.expectEqual(@as(u8, @sizeOf(Payload)), cmd.payload_len);
    try std.testing.expectEqual(@as(u8, @alignOf(Payload)), cmd.payload_align);
    try std.testing.expectEqual(p, cmd.read(Payload));
}
