const std = @import("std");
const ae = @import("aether");
const Util = ae.Util;
const test_app = @import("main.zig");

pub const std_options = Util.std_options;
pub const std_options_debug_threaded_io = std.Io.Threaded.global_single_threaded;
pub const std_options_debug_io: std.Io = std.Io.Threaded.global_single_threaded.io();

const gpa = std.heap.wasm_allocator;

var env_map: std.process.Environ.Map = undefined;
var env_map_initialized: bool = false;
var memory: []u8 = &.{};
var state: test_app.MyState = undefined;
var engine: ae.Engine = undefined;
var initialized: bool = false;

export fn aether_wasm_init(width: u32, height: u32) bool {
    if (initialized) return true;

    env_map = std.process.Environ.Map.init(gpa);
    env_map_initialized = true;

    const memory_config = webMemoryConfig();
    memory = gpa.alignedAlloc(u8, .fromByteUnits(16), memory_config.total()) catch return false;

    engine.init(std.Io.Threaded.global_single_threaded.io(), &env_map, memory, .{
        .memory = memory_config,
        .width = width,
        .height = height,
        .resizable = true,
    }, &state.state()) catch {
        gpa.free(memory);
        memory = &.{};
        env_map.deinit();
        env_map_initialized = false;
        return false;
    };
    engine.beginRun();
    initialized = true;
    return true;
}

export fn aether_wasm_frame() bool {
    if (!initialized) return false;
    return engine.stepFrame() catch false;
}

export fn aether_wasm_deinit() void {
    if (!initialized) return;
    initialized = false;
    engine.deinit();
    gpa.free(memory);
    memory = &.{};
    if (env_map_initialized) {
        env_map.deinit();
        env_map_initialized = false;
    }
}

export fn aether_wasm_alloc(len: usize) ?[*]u8 {
    const buf = gpa.alloc(u8, len) catch return null;
    return buf.ptr;
}

export fn aether_wasm_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}

fn webMemoryConfig() ae.Util.MemoryConfig {
    return .{
        .render = 12 * 1024 * 1024,
        .audio = 10 * 1024 * 1024,
        .game = 2 * 1024 * 1024,
        .user = 8 * 1024 * 1024,
    };
}
