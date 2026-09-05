const std = @import("std");
const assert = std.debug.assert;
const FogState = @import("../graphics/render_state.zig").FogState;

/// Each screen owns its table; command bindings are reset for every recording.
pub const Cache = struct {
    linear_depth: ?bool = null,
    depth_scale: ?f32 = null,
    enabled: ?bool = null,
    color: ?[3]u8 = null,
    table: ?[4]f32 = null,
    table_bound: bool = false,

    pub const Changes = struct {
        depth_mode: bool = false,
        depth_parameters: bool = false,
        effect: bool = false,
        color: bool = false,
        rebuild_table: bool = false,
        unbind_table: bool = false,
        bind_table: bool = false,
    };

    pub fn reset_commands(cache: *Cache) void {
        cache.* = .{ .table = cache.table };
    }

    pub fn update(cache: *Cache, fog: FogState) Changes {
        const linear_depth = fog.far > fog.near and fog.far > 0.0;
        assert(!fog.enabled or linear_depth);
        const depth_scale: f32 = if (linear_depth) -1.0 / fog.far else -1.0;
        var changes = Changes{
            .depth_mode = cache.linear_depth == null or cache.linear_depth.? != linear_depth,
            .depth_parameters = cache.depth_scale == null or cache.depth_scale.? != depth_scale,
            .effect = cache.enabled == null or cache.enabled.? != fog.enabled,
        };
        cache.linear_depth = linear_depth;
        cache.depth_scale = depth_scale;
        cache.enabled = fog.enabled;
        if (fog.enabled) {
            var color: [3]u8 = undefined;
            for (&color, fog.color) |*out, value| out.* = @intFromFloat(std.math.clamp(value, 0, 1) * 255);
            const table: [4]f32 = .{ fog.near, fog.far, fog.start, fog.end };
            changes.color = cache.color == null or !std.meta.eql(cache.color.?, color);
            changes.rebuild_table = cache.table == null or !std.meta.eql(cache.table.?, table);
            changes.unbind_table = changes.rebuild_table and cache.table_bound;
            changes.bind_table = changes.rebuild_table or !cache.table_bound;
            cache.color = color;
            cache.table = table;
            cache.table_bound = true;
        }
        return changes;
    }
};

test "fog transitions only change the affected GPU state" {
    var cache = Cache{};
    var fog = FogState{ .enabled = true, .near = 1, .far = 100, .start = 10, .end = 80 };
    try std.testing.expectEqual(Cache.Changes{
        .depth_mode = true,
        .depth_parameters = true,
        .effect = true,
        .color = true,
        .rebuild_table = true,
        .bind_table = true,
    }, cache.update(fog));
    try std.testing.expectEqual(Cache.Changes{}, cache.update(fog));
    fog.color[0] = 1;
    try std.testing.expectEqual(Cache.Changes{ .color = true }, cache.update(fog));
    fog.start = 20;
    try std.testing.expectEqual(Cache.Changes{ .rebuild_table = true, .unbind_table = true, .bind_table = true }, cache.update(fog));
    fog.enabled = false;
    try std.testing.expectEqual(Cache.Changes{ .effect = true }, cache.update(fog));
    fog.start = 30;
    fog.color[1] = 1;
    try std.testing.expectEqual(Cache.Changes{}, cache.update(fog));
    fog.enabled = true;
    try std.testing.expectEqual(Cache.Changes{ .effect = true, .color = true, .rebuild_table = true, .unbind_table = true, .bind_table = true }, cache.update(fog));
}

test "disabled fog still updates linear depth and fresh recordings rebind without rebuilding" {
    var cache = Cache{};
    var fog = FogState{ .near = 1, .far = 100 };
    _ = cache.update(fog);
    fog.far = 200;
    try std.testing.expectEqual(Cache.Changes{ .depth_parameters = true }, cache.update(fog));
    fog.enabled = true;
    fog.end = 100;
    _ = cache.update(fog);
    cache.reset_commands();
    try std.testing.expectEqual(Cache.Changes{
        .depth_mode = true,
        .depth_parameters = true,
        .effect = true,
        .color = true,
        .bind_table = true,
    }, cache.update(fog));
    // A second screen must build its own table even with identical parameters.
    var bottom = Cache{};
    try std.testing.expect(bottom.update(fog).rebuild_table);
    fog.near = 2;
    _ = bottom.update(fog);
    fog.near = 1;
    try std.testing.expectEqual(Cache.Changes{}, cache.update(fog));
}
