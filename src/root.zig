const std = @import("std");
const platform = @import("platform");

pub var GlobalAllocator = std.heap.GeneralPurposeAllocator(.{}){
    .backing_allocator = platform.Mem.BaseAllocator,
};
