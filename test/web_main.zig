//! Browser root for the test app. `main` initializes once; `engine.run()`
//! then hands the loop to the page, so the engine and its memory are static
//! and the page tears them down through the host.
const std = @import("std");
const ae = @import("aether");
const test_app = @import("main.zig");

pub const aether_options = test_app.aether_options;

var state: test_app.MyState = undefined;
var engine: ae.Engine = undefined;

pub fn main(init: std.process.Init) !void {
    const memory_config: ae.Util.MemoryConfig = .{
        .render = 12 * 1024 * 1024,
        .audio = 10 * 1024 * 1024,
        .game = 2 * 1024 * 1024,
        .frame = 2 * 1024 * 1024,
        .user = 8 * 1024 * 1024,
    };
    // Lives as long as the page; the host never returns it.
    const memory = try init.gpa.alignedAlloc(u8, .fromByteUnits(16), memory_config.total());
    errdefer init.gpa.free(memory);

    try engine.init(init.io, init.environ_map, memory, &.{
        .memory = memory_config,
        .title = aether_options.title,
        .app_name = ae.AppOptions.resolve_app_name(aether_options),
        .resizable = true,
    }, &state.state());
    try engine.run();
}
