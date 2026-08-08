const std = @import("std");
const Util = @import("util/util.zig");

pub const Version = struct {
    major: u8 = 1,
    minor: u8 = 0,
    patch: u8 = 0,
};

pub const PspModuleMode = enum {
    user,
    kernel,
};

pub const PspOptions = struct {
    module_name: ?[]const u8 = null,
    module_mode: PspModuleMode = .user,
    stack_size: u32 = 256 * 1024,
    async_stack_size: u32 = 128 * 1024,
    heap_kb_size: u32 = 0,
    heap_reserve_kb_size: u32 = 512,
};

pub const Nintendo3dsOptions = struct {
    stack_size: u32 = 768 * 1024,
    /// Total bounded PCM staging memory reserved from Engine's `.audio` pool
    /// for 3DS streaming playback. The backend splits this evenly across its
    /// hardware-mix slots; it never loads complete stream assets into this
    /// reservation. It must be at least 64 KiB and divisible by 16.
    audio_stream_cache_bytes: usize = 512 * 1024,
};

pub const Options = struct {
    title: [:0]const u8 = "Aether",
    app_name: ?[]const u8 = null,
    version: Version = .{},
    std_options: std.Options = Util.std_options,
    psp: PspOptions = .{},
    nintendo_3ds: Nintendo3dsOptions = .{},
};

pub fn resolveAppName(options: Options) []const u8 {
    return options.app_name orelse options.title;
}
