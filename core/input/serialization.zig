//! Versioned binding records for JSON or another caller-owned settings format.
//! The v1 source grammar is `<kind>:<device identifier>`, using the public
//! identifier spellings (for example `key:Space`, `gamepad_axis:LeftX`). Those
//! v1 spellings form a persistence contract, independent of Zig union layout.
const std = @import("std");
const data = @import("platform").input_api.data;
const binding = @import("binding.zig");

pub const Record = struct {
    version: u8 = 1,
    source: []const u8,
    component: []const u8 = "none",
    multiplier: f32 = 1,
    deadzone: f32 = binding.default_axis_deadzone,
};
/// The returned source string borrows `buffer`.
pub fn encode(value: binding.Binding, buffer: []u8) error{NoSpaceLeft}!Record {
    const source = switch (value.source) {
        inline else => |code, kind| try std.fmt.bufPrint(buffer, "{s}:{s}", .{ @tagName(kind), @tagName(code) }),
    };
    return .{ .source = source, .component = @tagName(value.component), .multiplier = value.multiplier, .deadzone = value.deadzone };
}
pub fn decode(record: Record) error{ UnsupportedVersion, InvalidBinding }!binding.Binding {
    if (record.version != 1) return error.UnsupportedVersion;
    if (!std.math.isFinite(record.multiplier) or !std.math.isFinite(record.deadzone) or record.deadzone < 0 or record.deadzone >= 1) return error.InvalidBinding;
    const colon = std.mem.indexOfScalar(u8, record.source, ':') orelse return error.InvalidBinding;
    const kind = std.meta.stringToEnum(binding.BindingSourceKind, record.source[0..colon]) orelse return error.InvalidBinding;
    const name = record.source[colon + 1 ..];
    const source: binding.BindingSource = switch (kind) {
        .key => .{ .key = std.meta.stringToEnum(data.Key, name) orelse return error.InvalidBinding },
        .mouse_button => .{ .mouse_button = std.meta.stringToEnum(data.MouseButton, name) orelse return error.InvalidBinding },
        .mouse_wheel => .{ .mouse_wheel = std.meta.stringToEnum(binding.Vec2Axis, name) orelse return error.InvalidBinding },
        .mouse_delta => .{ .mouse_delta = std.meta.stringToEnum(binding.Vec2Axis, name) orelse return error.InvalidBinding },
        .gamepad_button => .{ .gamepad_button = std.meta.stringToEnum(data.Button, name) orelse return error.InvalidBinding },
        .gamepad_axis => .{ .gamepad_axis = std.meta.stringToEnum(data.Axis, name) orelse return error.InvalidBinding },
    };
    return .{ .source = source, .component = std.meta.stringToEnum(binding.AxisComponent, record.component) orelse return error.InvalidBinding, .multiplier = record.multiplier, .deadzone = record.deadzone };
}
test "binding records round trip all source types and validate versions" {
    const sources = [_]binding.BindingSource{ .{ .key = .Space }, .{ .mouse_button = .Left }, .{ .mouse_wheel = .y }, .{ .mouse_delta = .x }, .{ .gamepad_button = .A }, .{ .gamepad_axis = .LeftX } };
    var buffer: [64]u8 = undefined;
    for (sources) |source| {
        const value: binding.Binding = .{ .source = source, .component = .x, .multiplier = -0.5, .deadzone = 0.25 };
        try std.testing.expectEqualDeep(value, try decode(try encode(value, &buffer)));
    }
    try std.testing.expectError(error.InvalidBinding, decode(.{ .source = "key:Missing" }));
    try std.testing.expectError(error.InvalidBinding, decode(.{ .source = "key:Space", .deadzone = 1 }));
    try std.testing.expectError(error.UnsupportedVersion, decode(.{ .version = 2, .source = "key:Space" }));
}
