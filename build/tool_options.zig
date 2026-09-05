const std = @import("std");

// Cached per-build user options. b.option panics on second declaration, so
// these getters declare once and memoize. Module-level mutable state is safe
// here: build.zig is single-threaded per invocation and build.zig instances
// don't live across invocations.
var molten_vk_path_cached: ?[]const u8 = null;
pub fn macos_molten_vk_path(b: *std.Build) []const u8 {
    if (molten_vk_path_cached) |p| return p;
    const p = b.option([]const u8, "molten-vk-path", "macOS: directory containing libMoltenVK.dylib (default: $(brew --prefix molten-vk)/lib)") orelse
        "/opt/homebrew/opt/molten-vk/lib";
    molten_vk_path_cached = p;
    return p;
}

var devkitpro_path_cached: ?[]const u8 = null;
pub fn devkit_pro_path(b: *std.Build) []const u8 {
    if (devkitpro_path_cached) |p| return p;
    const opt = b.option([]const u8, "devkitpro-path", "Switch: devkitPro install root (default: $DEVKITPRO or /opt/devkitpro)");
    const p = opt orelse b.graph.environ_map.get("DEVKITPRO") orelse "/opt/devkitpro";
    devkitpro_path_cached = p;
    return p;
}

var spirv_cross_path_cached: ?[]const u8 = null;
pub fn spirv_cross_path(b: *std.Build) []const u8 {
    if (spirv_cross_path_cached) |p| return p;
    const p = b.option([]const u8, "spirv-cross-path", "WASM/browser: spirv-cross executable path (default: spirv-cross)") orelse "spirv-cross";
    spirv_cross_path_cached = p;
    return p;
}
