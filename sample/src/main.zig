const std = @import("std");
const aether = @import("aether");

pub fn main() !void {
    std.debug.print("Hello, World!\n", .{});

    defer _ = aether.GlobalAllocator.deinit();

    const result = 3 + 7;
    const res = try std.fmt.allocPrint(aether.GlobalAllocator.allocator(), "{}", .{result});
    defer aether.GlobalAllocator.allocator().free(res);
    std.debug.print("Result: {s}\n", .{res});
}
