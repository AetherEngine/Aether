//! Browser process entry. The page calls `start` once from
//! `aether_wasm_init`; the application's `main` initializes (blocking) and
//! hands its run loop to `host_frame_loop` (Engine.run does) before
//! returning. Each animation frame then runs one loop iteration through
//! `frame`, and `stop` tears the loop's owner down.
const std = @import("std");
const assert = std.debug.assert;
const entry = @import("../entry.zig");
const AetherIo = @import("../io.zig").AetherIo;
const io = @import("io.zig");

const log = std.log.scoped(.aether_wasm_entry);
const gpa = std.heap.wasm_allocator;

pub const hosts_frame_loop = true;

var arena: std.heap.ArenaAllocator = undefined;
var environ_map: std.process.Environ.Map = undefined;
var aether_io: AetherIo = undefined;
var frame_loop: ?entry.FrameLoop = null;
var started = false;

/// True once the application's main returned with a run loop installed.
pub fn start(app_main: entry.AppMain) bool {
    if (started) return frame_loop != null;
    started = true;

    arena = .init(gpa);
    environ_map = .init(gpa);
    aether_io = .init(io.base(), gpa);
    const init: std.process.Init = .{
        .minimal = .{
            .environ = .empty,
            .args = if (std.process.Args.Vector == void) .{ .vector = {} } else .{ .vector = &.{} },
        },
        .arena = &arena,
        .gpa = gpa,
        .io = aether_io.io(),
        .environ_map = &environ_map,
        .preopens = .empty,
    };

    app_main(init) catch |err| {
        log.err("application main failed: {s}", .{@errorName(err)});
        return false;
    };
    if (frame_loop == null) {
        log.err("application main returned without handing its run loop to the host", .{});
        return false;
    }
    return true;
}

pub fn host_frame_loop(loop: entry.FrameLoop) void {
    assert(frame_loop == null);
    frame_loop = loop;
}

/// Runs one frame; false once the loop stopped or never started.
pub fn frame() bool {
    const loop = frame_loop orelse return false;
    return loop.step(loop.context);
}

pub fn stop() void {
    const loop = frame_loop orelse return;
    frame_loop = null;
    loop.finish(loop.context);
}

pub fn poll() bool {
    return true;
}

// Scratch buffers the page uses to pass strings (text input) into WASM.
export fn aether_wasm_alloc(len: usize) ?[*]u8 {
    const buffer = gpa.alloc(u8, len) catch return null;
    return buffer.ptr;
}

export fn aether_wasm_free(ptr: [*]u8, len: usize) void {
    gpa.free(ptr[0..len]);
}
