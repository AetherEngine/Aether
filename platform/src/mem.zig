const std = @import("std");
const Platform = @import("platform.zig").Platform;

pub const BaseAllocator = if (Platform == .PSP) @compileError("Not Implemented!") else std.heap.page_allocator;
