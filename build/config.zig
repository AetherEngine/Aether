const std = @import("std");

pub const Platform = enum {
    windows,
    linux,
    macos,
    wasm,
    psp,
    nintendo_3ds,
    /// Nintendo Switch. Zig 0.16 has no `switch`/`horizon` OS tag, so the
    /// canonical target is `aarch64-freestanding-none` and we can't infer
    /// the platform from `target.os.tag` alone. Opt in with
    /// `-Dnintendo-switch=true`; `Config.resolve` then promotes a
    /// freestanding aarch64 target to this variant.
    nintendo_switch,
};

pub const Gfx = enum {
    default,
    opengl,
    vulkan,
    webgl,
    headless,
};

pub const Audio = enum(u8) {
    default,
    none,
};

pub const Input = enum(u8) {
    default,
};

pub const PspDisplayMode = enum {
    rgba8888,
    rgb565,
};

pub const Config = struct {
    platform: Platform,
    gfx: Gfx,
    audio: Audio = Audio.default,
    input: Input = Input.default,
    psp_display_mode: PspDisplayMode = .rgba8888,
    /// When enabled, `force_texture_resident` also generates and binds mip
    /// levels for the texture. Off by default since the extra VRAM cost
    /// only pays off for textures sampled at a wide range of distances.
    psp_mipmaps: bool = false,
    /// When true, `Core.paths.resolve` returns CWD for both resources
    /// and data, bypassing the platform-specific layout (.app Resources
    /// on mac, APPDATA on Windows, XDG on Linux).
    ///
    /// Useful for:
    ///   - `zig build run-game` iterations where assets sit alongside
    ///     zig-out/bin/ and you don't want state cluttering your home
    ///     dir.
    ///   - CI jobs that compare runtime output against a known working
    ///     directory.
    ///   - Debug builds of unpackaged binaries on macOS, where resources
    ///     aren't inside a .app yet.
    use_cwd: bool = false,
    /// Flush the file log after every message. Useful for diagnosing hard
    /// hangs on consoles where normal shutdown never reaches logger.deinit.
    flush_logs: bool = false,
    /// When enabled, mesh helpers emit index buffers and backends draw through
    /// indexed paths when an index buffer is uploaded.
    mesh_indexing: bool = true,

    pub fn resolve(target: std.Build.ResolvedTarget, overrides: Overrides) Config {
        const plat: Platform = blk: {
            if (overrides.nintendo_switch == true) {
                if (target.result.cpu.arch != .aarch64 or target.result.os.tag != .freestanding) {
                    std.debug.panic(
                        "-Dnintendo-switch=true requires -Dtarget=aarch64-freestanding-none (got {s}-{s})\n",
                        .{ @tagName(target.result.cpu.arch), @tagName(target.result.os.tag) },
                    );
                }
                break :blk .nintendo_switch;
            }
            break :blk switch (target.result.os.tag) {
                .windows => .windows,
                .macos => .macos,
                .linux => .linux,
                .wasi => .wasm,
                .psp => .psp,
                .@"3ds" => .nintendo_3ds,
                else => |t| {
                    std.debug.panic("Unsupported OS! {}\n", .{t});
                },
            };
        };

        const default_gfx: Gfx = switch (target.result.os.tag) {
            .windows => .vulkan,
            .macos => .vulkan,
            .linux => .vulkan,
            .wasi => .webgl,
            else => .default,
        };
        const resolved_gfx = overrides.gfx orelse default_gfx;
        const default_mesh_indexing = plat != .psp and resolved_gfx != .headless;

        const default_audio: Audio = .default;

        return .{
            .platform = plat,
            .gfx = resolved_gfx,
            .audio = overrides.audio orelse default_audio,
            .psp_display_mode = overrides.psp_display_mode orelse .rgba8888,
            .psp_mipmaps = overrides.psp_mipmaps orelse false,
            .use_cwd = overrides.use_cwd orelse false,
            .flush_logs = overrides.flush_logs orelse false,
            .mesh_indexing = overrides.mesh_indexing orelse default_mesh_indexing,
        };
    }

    pub const Overrides = struct {
        gfx: ?Gfx = null,
        audio: ?Audio = null,
        psp_display_mode: ?PspDisplayMode = null,
        psp_mipmaps: ?bool = null,
        use_cwd: ?bool = null,
        flush_logs: ?bool = null,
        mesh_indexing: ?bool = null,
        /// Promotes an `aarch64-freestanding-none` target to the
        /// `nintendo_switch` platform. No effect when null/false.
        nintendo_switch: ?bool = null,
    };
};

pub fn webTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .wasi,
        .abi = .musl,
        .cpu_features_add = std.Target.wasm.featureSet(&.{ .atomics, .bulk_memory }),
    });
}

pub fn nintendo3dsTarget(b: *std.Build) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .@"3ds",
    });
}
