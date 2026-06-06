const std = @import("std");
const c_io = @import("c_io.zig");
const options = @import("options");

const ProcessHeap = if (options.config.platform == .nintendo_3ds) struct {
    extern fn linearMemAlign(size: usize, alignment: usize) ?*anyopaque;
    extern fn linearFree(ptr: ?*anyopaque) void;

    fn alloc(alignment: usize, size: usize) ?*anyopaque {
        return linearMemAlign(size, alignment);
    }

    fn free(ptr: ?*anyopaque) void {
        linearFree(ptr);
    }
} else struct {
    extern fn memalign(alignment: usize, size: usize) ?*anyopaque;
    extern fn free(ptr: ?*anyopaque) void;

    fn alloc(alignment: usize, size: usize) ?*anyopaque {
        return memalign(alignment, size);
    }
};

var arena_state: std.heap.ArenaAllocator = undefined;
var environ_map_state: std.process.Environ.Map = undefined;

const allocator_vtable: std.mem.Allocator.VTable = .{
    .alloc = alloc,
    .resize = resize,
    .remap = remap,
    .free = dealloc,
};

pub fn makeInit(args: std.process.Args) std.process.Init {
    const gpa = allocator();
    arena_state = std.heap.ArenaAllocator.init(gpa);
    environ_map_state = std.process.Environ.Map.init(gpa);

    return .{
        .minimal = .{
            .environ = std.process.Environ.empty,
            .args = args,
        },
        .arena = &arena_state,
        .gpa = gpa,
        .io = c_io.io(),
        .environ_map = &environ_map_state,
        .preopens = std.process.Preopens.empty,
    };
}

fn allocator() std.mem.Allocator {
    return .{
        .ptr = undefined,
        .vtable = &allocator_vtable,
    };
}

fn alloc(
    _: *anyopaque,
    len: usize,
    alignment: std.mem.Alignment,
    _: usize,
) ?[*]u8 {
    std.debug.assert(len > 0);

    const effective_alignment = @max(alignment.toByteUnits(), @sizeOf(usize));
    const ptr = ProcessHeap.alloc(effective_alignment, len) orelse return null;
    std.debug.assert(alignment.check(@intFromPtr(ptr)));
    return @ptrCast(ptr);
}

fn resize(
    _: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    new_len: usize,
    _: usize,
) bool {
    std.debug.assert(memory.len > 0);
    std.debug.assert(new_len > 0);
    return new_len <= memory.len;
}

fn remap(
    _: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    new_len: usize,
    _: usize,
) ?[*]u8 {
    std.debug.assert(memory.len > 0);
    std.debug.assert(new_len > 0);
    return if (new_len <= memory.len) memory.ptr else null;
}

fn dealloc(
    _: *anyopaque,
    memory: []u8,
    _: std.mem.Alignment,
    _: usize,
) void {
    std.debug.assert(memory.len > 0);
    ProcessHeap.free(memory.ptr);
}
