const std = @import("std");
const pspsdk = @import("pspsdk");
const zitrus = @import("zitrus");

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

        const default_audio: Audio = .default;

        return .{
            .platform = plat,
            .gfx = overrides.gfx orelse default_gfx,
            .audio = overrides.audio orelse default_audio,
            .psp_display_mode = overrides.psp_display_mode orelse .rgba8888,
            .psp_mipmaps = overrides.psp_mipmaps orelse false,
            .use_cwd = overrides.use_cwd orelse false,
            .flush_logs = overrides.flush_logs orelse false,
        };
    }

    pub const Overrides = struct {
        gfx: ?Gfx = null,
        audio: ?Audio = null,
        psp_display_mode: ?PspDisplayMode = null,
        psp_mipmaps: ?bool = null,
        use_cwd: ?bool = null,
        flush_logs: ?bool = null,
        /// Promotes an `aarch64-freestanding-none` target to the
        /// `nintendo_switch` platform. No effect when null/false.
        nintendo_switch: ?bool = null,
    };
};

pub const GameOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
    overrides: Config.Overrides = .{},
};

pub const HeadlessOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
    overrides: Config.Overrides = .{},
};

const ShaderStagePaths = struct {
    vert: std.Build.LazyPath,
    frag: std.Build.LazyPath,
};

const user_root_import_name = "aether_user_root";

pub fn userRootModule(exe: *std.Build.Step.Compile) *std.Build.Module {
    return exe.root_module.import_table.get(user_root_import_name) orelse exe.root_module;
}

// Cached per-build user options. b.option panics on second declaration, so
// these getters declare once and memoize. Accessed from both addGame (for
// linking) and exportArtifact (for bundle packaging). Module-level mutable
// state is safe here: build.zig is single-threaded per invocation and
// build.zig instances don't live across invocations.
var molten_vk_path_cached: ?[]const u8 = null;
fn macosMoltenVkPath(b: *std.Build) []const u8 {
    if (molten_vk_path_cached) |p| return p;
    const p = b.option([]const u8, "molten-vk-path", "macOS: directory containing libMoltenVK.dylib (default: $(brew --prefix molten-vk)/lib)") orelse
        "/opt/homebrew/opt/molten-vk/lib";
    molten_vk_path_cached = p;
    return p;
}

var glfw_path_cached: ?[]const u8 = null;
fn macosGlfwPath(b: *std.Build) []const u8 {
    if (glfw_path_cached) |p| return p;
    const p = b.option([]const u8, "glfw-path", "macOS: directory containing libglfw.3.dylib (default: $(brew --prefix glfw)/lib)") orelse
        "/opt/homebrew/opt/glfw/lib";
    glfw_path_cached = p;
    return p;
}

var devkitpro_path_cached: ?[]const u8 = null;
fn devkitProPath(b: *std.Build) []const u8 {
    if (devkitpro_path_cached) |p| return p;
    const opt = b.option([]const u8, "devkitpro-path", "Switch: devkitPro install root (default: $DEVKITPRO or /opt/devkitpro)");
    const p = opt orelse b.graph.environ_map.get("DEVKITPRO") orelse "/opt/devkitpro";
    devkitpro_path_cached = p;
    return p;
}

var spirv_cross_path_cached: ?[]const u8 = null;
fn spirvCrossPath(b: *std.Build) []const u8 {
    if (spirv_cross_path_cached) |p| return p;
    const p = b.option([]const u8, "spirv-cross-path", "WASM/browser: spirv-cross executable path (default: spirv-cross)") orelse "spirv-cross";
    spirv_cross_path_cached = p;
    return p;
}

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

fn addNintendoCImportPaths(_: *std.Build, mod: *std.Build.Module, config: Config, dkp: []const u8) void {
    const b = mod.owner;
    switch (config.platform) {
        .nintendo_switch => {
            // Zig's Switch C import can otherwise see newlib's fortified
            // wrappers and emit references to __ssp_real_* symbols.
            mod.addCMacro("_FORTIFY_SOURCE", "0");
            mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dkp, "devkitA64/aarch64-none-elf/include" }) });
            mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dkp, "libnx/include" }) });
        },
        else => {},
    }
}

/// Creates an executable with the Aether engine module and all platform
/// dependencies wired up. Returns the compile step so the caller can
/// further customize it (install, add run steps, etc.).
///
/// When called from Aether's own build, use `addGame(b, b, opts)`.
/// From a downstream project:
///
///     const ae_dep = b.dependency("aether", .{ ... });
///     const exe = Aether.addGame(ae_dep.builder, b, .{ ... });
///
/// `owner` is the Build that owns Aether's dependencies (pspsdk, zglfw,
/// etc.), while `b` is the downstream project's builder that creates
/// the actual build steps and executable.
pub fn addGame(owner: *std.Build, b: *std.Build, opts: GameOptions) *std.Build.Step.Compile {
    const config = Config.resolve(opts.target, opts.overrides);
    const uses_nintendo_c_io = config.platform == .nintendo_switch;
    const uses_zitrus = config.platform == .nintendo_3ds;

    // Switch forces ofmt=c -- there's no Zig-native backend for Horizon yet,
    // so we emit C and let devkitA64/libnx compile the result.
    const target = if (uses_nintendo_c_io) blk: {
        var q = opts.target.query;
        q.ofmt = .c;
        break :blk b.resolveTargetQuery(q);
    } else opts.target;

    const options = b.addOptions();
    options.addOption(Config, "config", config);
    const options_module = options.createModule();

    const mod = b.addModule("Aether", .{
        .root_source_file = owner.path("src/root.zig"),
        .target = target,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "options", .module = options_module },
        },
    });

    // --- platform-specific engine dependencies ---
    const psp_dep = if (config.platform == .psp) owner.dependency("pspsdk", .{
        .target = target,
        .optimize = opts.optimize,
    }) else null;
    const zitrus_dep = if (uses_zitrus) owner.dependency("zitrus", .{}) else null;

    if (psp_dep) |pd| {
        mod.addImport("pspsdk", pd.module("pspsdk"));
    } else if (zitrus_dep) |zd| {
        mod.addImport("zitrus", zd.module("zitrus"));
    } else if (config.platform == .nintendo_switch) {
        // Console SDK symbols are declared as backend-local externs and
        // resolved by the export pipeline's devkitPro link step.
    } else if (config.platform == .wasm) {
        // Browser builds use host imports for WebGL/Web Audio/input and WASI
        // imports for files, clocks, stdio, random, and environment. They do
        // not link desktop windowing/audio dependencies.
    } else {
        const zglfw = owner.dependency("zglfw", .{
            .target = target,
            .optimize = opts.optimize,
        });

        const glfw = owner.dependency("glfw_zig", .{
            .target = target,
            .optimize = opts.optimize,
        });

        const gl_bindings = @import("zigglgen").generateBindingsModule(owner, .{
            .api = .gl,
            .version = .@"4.5",
            .profile = .core,
        });

        const vulkan = owner.dependency("vulkan", .{
            .registry = owner.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
        }).module("vulkan-zig");

        mod.addImport("glfw", zglfw.module("glfw"));
        mod.addImport("gl", gl_bindings);
        mod.addImport("vulkan", vulkan);

        if (config.audio != .none) {
            const sdl3_dep = owner.lazyDependency("sdl3", .{
                .target = target,
                .optimize = opts.optimize,
                .main = false,
                .ext_image = false,
                .ext_net = false,
                .ext_ttf = false,
                // Static SDL3 and static GLFW both embed generated Wayland
                // protocol objects on Linux. Keep SDL dynamic there since
                // Aether only uses its audio subsystem.
                .c_sdl_preferred_linkage = @as(
                    std.builtin.LinkMode,
                    if (target.result.os.tag == .linux) .dynamic else .static,
                ),
            }) orelse @panic("sdl3 dependency is required when desktop audio is enabled");
            mod.addImport("sdl3", sdl3_dep.module("sdl3"));

            if (target.result.os.tag == .linux) {
                mod.addRPathSpecial("$ORIGIN");
                const install_sdl3 = b.addInstallArtifact(sdl3_dep.artifact("SDL3"), .{
                    .dest_dir = .{ .override = .bin },
                });
                b.getInstallStep().dependOn(&install_sdl3.step);
            }
        }

        if (target.result.os.tag == .macos) {
            // Link MoltenVK directly as the Vulkan ICD -- no loader. Feeds
            // its vkGetInstanceProcAddr into GLFW via glfwInitVulkanLoader
            // in platform/glfw/surface.zig so GLFW doesn't dlopen libvulkan
            // (which is brittle across brew/SDK installs).
            mod.addLibraryPath(.{ .cwd_relative = macosMoltenVkPath(b) });
            mod.addLibraryPath(.{ .cwd_relative = macosGlfwPath(b) });
            mod.linkSystemLibrary("MoltenVK", .{});
            mod.linkSystemLibrary("glfw3", .{});

            // rpath for the .app bundle layout: exe in Contents/MacOS/, dylibs
            // in Contents/Frameworks/. Harmless when running bare out of
            // zig-out/bin (only consulted after absolute paths fail).
            mod.addRPathSpecial("@executable_path/../Frameworks");

            if (owner.lazyDependency("system_sdk", .{})) |system_sdk| {
                mod.addFrameworkPath(system_sdk.path("macos12/System/Library/Frameworks"));
                mod.addSystemIncludePath(system_sdk.path("macos12/usr/include"));
                mod.addLibraryPath(system_sdk.path("macos12/usr/lib"));
            }
        } else {
            mod.linkLibrary(glfw.artifact("glfw"));
        }
    }

    if (uses_nintendo_c_io) {
        addNintendoCImportPaths(owner, mod, config, devkitProPath(b));
    }
    addInternalShaderModule(owner, b, mod, config);

    // --- user executable ---
    const user_mod = b.createModule(.{
        .root_source_file = opts.root_source_file,
        .target = target,
        .optimize = opts.optimize,
        .strip = if (config.platform == .psp) false else null,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "aether", .module = mod },
        },
    });
    if (zitrus_dep) |zd| {
        user_mod.addImport("zitrus", zd.module("zitrus"));
    }

    const root_mod = if (uses_nintendo_c_io or uses_zitrus) b.createModule(.{
        .root_source_file = owner.path(switch (config.platform) {
            .nintendo_switch => "src/platform/switch/services.zig",
            .nintendo_3ds => "src/platform/3ds/entry.zig",
            else => unreachable,
        }),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
            .{ .name = "options", .module = options_module },
        },
    }) else user_mod;
    if (zitrus_dep) |zd| {
        root_mod.addImport("zitrus", zd.module("zitrus"));
    }
    if (uses_nintendo_c_io) {
        addNintendoCImportPaths(owner, root_mod, config, devkitProPath(b));
    }

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = root_mod,
        .zig_lib_dir = if (zitrus_dep) |zd| zd.namedLazyPath("juice/zig_lib") else null,
    });

    if (psp_dep) |pd| {
        // Inline PSP config -- pspsdk.configurePspExecutable uses
        // dependencyFromBuildZig on exe.step.owner which fails when
        // the exe is owned by a downstream builder.
        if (userRootModule(exe).import_table.get("pspsdk") == null) {
            userRootModule(exe).addImport("pspsdk", mod.import_table.get("pspsdk").?);
        }
        exe.link_eh_frame_hdr = true;
        exe.link_emit_relocs = true;
        exe.entry = .{ .symbol_name = "module_start" };
        exe.setLinkerScript(pd.path("tools/linkfile.ld"));
    }

    if (zitrus_dep) |zd| {
        if (userRootModule(exe).import_table.get("zitrus") == null) {
            userRootModule(exe).addImport("zitrus", zd.module("zitrus"));
        }
        exe.pie = true;
        exe.setLinkerScript(zd.namedLazyPath("horizon/ld"));
    }

    if (config.platform == .windows and (opts.optimize == .ReleaseFast or opts.optimize == .ReleaseSmall)) {
        exe.subsystem = .windows;
    }

    if (uses_nintendo_c_io) {
        // The platform shim exports C `main` itself. Keeping std/start's
        // libc main wrapper disabled avoids pulling in unsupported
        // freestanding libc/thread startup paths while still preserving the
        // exported shim in the emitted C.
        exe.entry = .disabled;
    } else if (config.platform == .wasm) {
        exe.entry = .disabled;
        exe.rdynamic = true;
        exe.wasi_exec_model = .reactor;
        exe.shared_memory = true;
        exe.initial_memory = 64 * 1024 * 1024;
        exe.max_memory = 256 * 1024 * 1024;
    }

    return exe;
}

/// Creates an executable with the Aether engine module in headless mode
/// (no graphics, no windowing, no input). Useful for servers, tools, and
/// tests that only need engine logic (math, state machine, allocator).
///
/// Usage is the same as `addGame` but without graphics dependencies:
///
///     const exe = Aether.addHeadless(ae_dep.builder, b, .{ ... });
///
pub fn addHeadless(owner: *std.Build, b: *std.Build, opts: HeadlessOptions) *std.Build.Step.Compile {
    // Headless ignores any caller-supplied gfx/audio overrides -- those
    // backends are always stubbed in this mode. Other knobs (use_cwd,
    // PSP display/mip) flow through unchanged.
    var config = Config.resolve(opts.target, opts.overrides);
    config.gfx = .headless;
    config.audio = .none;
    const uses_nintendo_c_io = config.platform == .nintendo_switch;
    const uses_zitrus = config.platform == .nintendo_3ds;

    // Switch forces ofmt=c (see addGame for details).
    const target = if (uses_nintendo_c_io) blk: {
        var q = opts.target.query;
        q.ofmt = .c;
        break :blk b.resolveTargetQuery(q);
    } else opts.target;

    const options = b.addOptions();
    options.addOption(Config, "config", config);
    const options_module = options.createModule();

    const mod = b.addModule("Aether", .{
        .root_source_file = owner.path("src/root.zig"),
        .target = target,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "options", .module = options_module },
        },
    });

    const psp_dep = if (config.platform == .psp) owner.dependency("pspsdk", .{
        .target = target,
        .optimize = opts.optimize,
    }) else null;
    const zitrus_dep = if (uses_zitrus) owner.dependency("zitrus", .{}) else null;

    if (psp_dep) |pd| {
        mod.addImport("pspsdk", pd.module("pspsdk"));
    } else if (zitrus_dep) |zd| {
        mod.addImport("zitrus", zd.module("zitrus"));
    }

    if (uses_nintendo_c_io) {
        addNintendoCImportPaths(owner, mod, config, devkitProPath(b));
    }

    const user_mod = b.createModule(.{
        .root_source_file = opts.root_source_file,
        .target = target,
        .optimize = opts.optimize,
        .strip = if (config.platform == .psp) false else null,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "aether", .module = mod },
        },
    });
    if (zitrus_dep) |zd| {
        user_mod.addImport("zitrus", zd.module("zitrus"));
    }

    const root_mod = if (uses_nintendo_c_io or uses_zitrus) b.createModule(.{
        .root_source_file = owner.path(switch (config.platform) {
            .nintendo_switch => "src/platform/switch/services.zig",
            .nintendo_3ds => "src/platform/3ds/entry.zig",
            else => unreachable,
        }),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
            .{ .name = "options", .module = options_module },
        },
    }) else user_mod;
    if (zitrus_dep) |zd| {
        root_mod.addImport("zitrus", zd.module("zitrus"));
    }
    if (uses_nintendo_c_io) {
        addNintendoCImportPaths(owner, root_mod, config, devkitProPath(b));
    }

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = root_mod,
        .zig_lib_dir = if (zitrus_dep) |zd| zd.namedLazyPath("juice/zig_lib") else null,
    });

    if (psp_dep) |pd| {
        if (userRootModule(exe).import_table.get("pspsdk") == null) {
            userRootModule(exe).addImport("pspsdk", mod.import_table.get("pspsdk").?);
        }
        exe.link_eh_frame_hdr = true;
        exe.link_emit_relocs = true;
        exe.entry = .{ .symbol_name = "module_start" };
        exe.setLinkerScript(pd.path("tools/linkfile.ld"));
    }

    if (zitrus_dep) |zd| {
        if (userRootModule(exe).import_table.get("zitrus") == null) {
            userRootModule(exe).addImport("zitrus", zd.module("zitrus"));
        }
        exe.pie = true;
        exe.setLinkerScript(zd.namedLazyPath("horizon/ld"));
    }

    if (uses_nintendo_c_io) {
        exe.entry = .disabled;
    } else if (config.platform == .wasm) {
        exe.entry = .disabled;
        exe.rdynamic = true;
        exe.wasi_exec_model = .reactor;
        exe.shared_memory = true;
        exe.initial_memory = 64 * 1024 * 1024;
        exe.max_memory = 256 * 1024 * 1024;
    }

    return exe;
}

fn slangcPath(owner: *std.Build) ?std.Build.LazyPath {
    const builtin = @import("builtin");
    const dep_name = switch (builtin.os.tag) {
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => "slangc_linux_x86_64",
            else => @compileError("No slangc binary for this Linux architecture"),
        },
        .macos => switch (builtin.cpu.arch) {
            .x86_64 => "slangc_macos_x86_64",
            .aarch64 => "slangc_macos_aarch64",
            else => @compileError("No slangc binary for this macOS architecture"),
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => "slangc_windows_x86_64",
            else => @compileError("No slangc binary for this Windows architecture"),
        },
        else => @compileError("No slangc binary for this OS"),
    };
    const dep = owner.lazyDependency(dep_name, .{}) orelse return null;
    const exe_name = if (builtin.os.tag == .windows) "bin/slangc.exe" else "bin/slangc";
    return dep.path(exe_name);
}

fn requireSlangcPath(owner: *std.Build) std.Build.LazyPath {
    return slangcPath(owner) orelse @panic("slangc dependency unavailable; run zig build --fetch");
}

fn addSlangStep(b: *std.Build, slangc: std.Build.LazyPath, args: []const []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = std.Build.Step.Run.create(b, "slangc " ++ output_name);
    run.addFileArg(slangc);
    run.addArgs(args);
    run.addArg("-o");
    const output = run.addOutputFileArg(output_name);
    run.addFileArg(input);
    return output;
}

fn addSpirvCrossStep(b: *std.Build, spirv_cross: []const u8, args: []const []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{spirv_cross});
    run.setName("spirv-cross " ++ output_name);
    run.addFileArg(input);
    run.addArgs(args);
    run.addArg("--output");
    return run.addOutputFileArg(output_name);
}

fn addUamStep(b: *std.Build, uam: []const u8, stage: []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ uam, "-s", stage, "-o" });
    const output = run.addOutputFileArg(output_name);
    run.addFileArg(input);
    return output;
}

fn addInternalShaderModule(owner: *std.Build, b: *std.Build, mod: *std.Build.Module, config: Config) void {
    const stages = internalShaderStages(owner, b, config) orelse return;

    const files = b.addWriteFiles();
    _ = files.addCopyFile(stages.vert, "basic.vert");
    _ = files.addCopyFile(stages.frag, "basic.frag");
    const root = files.add("aether_shaders.zig",
        \\pub const basic_vert align(@alignOf(u32)) = @embedFile("basic.vert").*;
        \\pub const basic_frag align(@alignOf(u32)) = @embedFile("basic.frag").*;
        \\
    );

    mod.addImport("aether_shaders", b.createModule(.{
        .root_source_file = root,
    }));
}

fn internalShaderStages(owner: *std.Build, b: *std.Build, config: Config) ?ShaderStagePaths {
    if (config.platform == .nintendo_switch and config.gfx == .default) {
        const uam = b.pathJoin(&.{ devkitProPath(b), "tools/bin/uam" });
        const slangc = requireSlangcPath(owner);
        const source = owner.path("src/rendering/shaders/basic.slang");
        const vert_glsl = addSlangStep(b, slangc, &.{
            "-target",       "glsl",       "-matrix-layout-column-major",
            "-DAETHER_DEKO", "-profile",   "glsl_450",
            "-entry",        "vertexMain", "-stage",
            "vertex",
        }, "basic.vert.switch.glsl", source);
        const frag_glsl = addSlangStep(b, slangc, &.{
            "-target",       "glsl",         "-matrix-layout-column-major",
            "-DAETHER_DEKO", "-profile",     "glsl_450",
            "-entry",        "fragmentMain", "-stage",
            "fragment",
        }, "basic.frag.switch.glsl", source);
        return .{
            .vert = addUamStep(
                b,
                uam,
                "vert",
                "basic.vert.dksh",
                vert_glsl,
            ),
            .frag = addUamStep(
                b,
                uam,
                "frag",
                "basic.frag.dksh",
                frag_glsl,
            ),
        };
    }

    switch (config.gfx) {
        .vulkan => {
            const slangc = requireSlangcPath(owner);
            const source = owner.path("src/rendering/shaders/basic.slang");
            return .{
                .vert = addSlangStep(b, slangc, &.{
                    "-target",  "spirv",  "-emit-spirv-directly", "-matrix-layout-column-major",
                    "-DVULKAN", "-entry", "vertexMain",           "-stage",
                    "vertex",
                }, "basic.vert.spv", source),
                .frag = addSlangStep(b, slangc, &.{
                    "-target",  "spirv",  "-emit-spirv-directly", "-matrix-layout-column-major",
                    "-DVULKAN", "-entry", "fragmentMain",         "-stage",
                    "fragment",
                }, "basic.frag.spv", source),
            };
        },
        .opengl => {
            const slangc = requireSlangcPath(owner);
            const source = owner.path("src/rendering/shaders/basic.slang");
            return .{
                .vert = addSlangStep(b, slangc, &.{
                    "-target",    "glsl",     "-matrix-layout-column-major",
                    "-profile",   "glsl_450", "-entry",
                    "vertexMain", "-stage",   "vertex",
                }, "basic.vert.glsl", source),
                .frag = addSlangStep(b, slangc, &.{
                    "-target",      "glsl",     "-matrix-layout-column-major",
                    "-profile",     "glsl_450", "-entry",
                    "fragmentMain", "-stage",   "fragment",
                }, "basic.frag.glsl", source),
            };
        },
        .webgl => {
            const slangc = requireSlangcPath(owner);
            const spirv_cross = spirvCrossPath(b);
            const source = owner.path("src/rendering/shaders/basic.slang");
            const vert_spv = addSlangStep(b, slangc, &.{
                "-entry",   "vertexMain", "-stage",               "vertex",
                "-profile", "glsl_330",   "-emit-spirv-via-glsl", "-matrix-layout-column-major",
            }, "basic.vert.webgl.spv", source);
            const frag_spv = addSlangStep(b, slangc, &.{
                "-entry",   "fragmentMain", "-stage",               "fragment",
                "-profile", "glsl_330",     "-emit-spirv-via-glsl", "-matrix-layout-column-major",
            }, "basic.frag.webgl.spv", source);
            return .{
                .vert = addSpirvCrossStep(b, spirv_cross, &.{
                    "--es",                        "--version",                   "300",
                    "--rename-interface-variable", "out",                         "0",
                    "v_uv",                        "--rename-interface-variable", "out",
                    "1",                           "v_color",                     "--rename-interface-variable",
                    "out",                         "2",                           "v_viewDepth",
                }, "basic.vert.webgl.glsl", vert_spv),
                .frag = addSpirvCrossStep(b, spirv_cross, &.{
                    "--es",                        "--version",                   "300",
                    "--rename-interface-variable", "in",                          "0",
                    "v_uv",                        "--rename-interface-variable", "in",
                    "1",                           "v_color",                     "--rename-interface-variable",
                    "in",                          "2",                           "v_viewDepth",
                }, "basic.frag.webgl.glsl", frag_spv),
            };
        },
        .default, .headless => return null,
    }
}

pub const ExportOptions = struct {
    /// PSP/macOS: human-readable name shown to the OS (XMB title on PSP,
    /// CFBundleName on macOS). Ignored elsewhere.
    title: []const u8 = "",
    /// PSP: subdirectory under zig-out/bin/ for EBOOT artifacts.
    /// Defaults to the executable name. Ignored on other platforms.
    output_dir: ?[]const u8 = null,
    /// PSP: optional PBP assets.
    icon0: ?std.Build.LazyPath = null,
    icon1: ?std.Build.LazyPath = null,
    pic0: ?std.Build.LazyPath = null,
    pic1: ?std.Build.LazyPath = null,
    snd0: ?std.Build.LazyPath = null,
    /// macOS: reverse-DNS bundle identifier for Info.plist (CFBundleIdentifier).
    /// Defaults to "com.aether.<exe-name>".
    bundle_id: ?[]const u8 = null,
    /// macOS: PNG icon to use for the bundle. Compiled to AppIcon.icns at
    /// build time via `sips` + `iconutil` (mac-only tools, which is fine --
    /// the .app branch only runs on mac builds). 1024x1024 PNG is ideal
    /// since every other size downscales cleanly from that; smaller
    /// sources are upscaled via bilinear, which is fine for placeholders.
    icon_png: ?std.Build.LazyPath = null,
    /// Files to install into the app bundle. On macOS they land under
    /// `Contents/Resources/<name>`. On desktop non-macOS they are copied
    /// alongside the exe in `zig-out/bin/`. Ignored on PSP.
    resources: []const Resource = &.{},
    /// WASM/browser: directory copied into the web artifact root and exposed
    /// through `resources.manifest` for the JavaScript WASI preloader.
    web_resources: ?std.Build.LazyPath = null,
    /// WASM/browser: individual files copied into the web artifact root.
    web_resource_files: []const Resource = &.{},
    /// WASM/browser: newline-delimited resource paths relative to
    /// `web_resources`.
    web_resource_manifest: []const u8 = "",
    /// WASM/browser: destination wasm filename. Defaults to the name expected
    /// by the stock Aether web loader.
    web_wasm_name: []const u8 = "Aether.wasm",
    /// Switch: NACP author string (shows under the title in the HOME
    /// menu). Empty falls back to "Aether".
    switch_author: []const u8 = "",
    /// Switch: NACP version string (e.g. "1.0.0"). Empty falls back to
    /// "1.0.0".
    switch_version: []const u8 = "",
    /// Switch: 256x256 JPEG icon embedded in the NRO. When null, libnx's
    /// `default_icon.jpg` is used.
    switch_icon: ?std.Build.LazyPath = null,
    /// Switch: directory embedded into the NRO as RomFS. When null, no
    /// RomFS is attached.
    switch_romfs: ?std.Build.LazyPath = null,
    /// 3DS: publisher string embedded in SMDH metadata. Empty falls back to
    /// "Aether".
    nintendo_3ds_publisher: []const u8 = "",
    /// 3DS: 48x48 icon embedded in SMDH metadata. When null, Zitrus' default
    /// icon is used.
    nintendo_3ds_icon: ?std.Build.LazyPath = null,
    /// 3DS: directory embedded into the 3DSX as RomFS. When null, no RomFS is
    /// attached.
    nintendo_3ds_romfs: ?std.Build.LazyPath = null,

    pub const Resource = struct {
        /// Source file to copy.
        path: std.Build.LazyPath,
        /// Destination name inside Resources/ (or alongside exe on non-mac).
        name: []const u8,
    };
};

/// Installs the game executable with platform-appropriate packaging.
/// - PSP: ELF -> PRX -> SFO -> EBOOT.PBP pipeline.
/// - macOS: produces a `<name>.app` bundle under `zig-out/bin/` with
///   MoltenVK + glfw3 dylibs in `Contents/Frameworks/`, load-command
///   paths rewritten to `@rpath`, and ad-hoc codesign applied.
/// - Other desktop: plain `b.installArtifact`, plus any `opts.resources`
///   copied alongside the exe.
pub fn exportArtifact(owner: *std.Build, b: *std.Build, exe: *std.Build.Step.Compile, config: Config, opts: ExportOptions) void {
    if (config.platform == .psp) {
        // Resolve pspsdk artifacts from `owner` (which has pspsdk in its
        // dep tree), but run the pipeline on `b` so install steps
        // register on the downstream project's builder.
        const psp_dep = owner.dependency("pspsdk", .{});
        _ = pspEbootPipeline(b, exe, psp_dep, opts);
    } else if (config.platform == .nintendo_3ds) {
        nintendo3dsPipeline(owner, b, exe, opts);
    } else if (config.platform == .nintendo_switch) {
        switchNroPipeline(b, exe, opts);
    } else if (config.platform == .wasm) {
        const install = addWebBundle(owner, b, exe, opts);
        b.getInstallStep().dependOn(&install.step);
    } else if (config.platform == .macos) {
        macosAppBundle(b, exe, opts);
    } else {
        b.installArtifact(exe);
        for (opts.resources) |res| {
            const install_res = b.addInstallBinFile(res.path, res.name);
            b.getInstallStep().dependOn(&install_res.step);
        }
    }
}

pub fn addWebBundle(owner: *std.Build, b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) *std.Build.Step.InstallDir {
    const web = b.addWriteFiles();
    _ = web.addCopyFile(exe.getEmittedBin(), opts.web_wasm_name);
    _ = web.addCopyFile(owner.path("web/index.html"), "index.html");
    _ = web.addCopyFile(owner.path("web/aether.js"), "aether.js");
    _ = web.add("resources.manifest", opts.web_resource_manifest);
    if (opts.web_resources) |resource_dir| {
        _ = web.addCopyDirectory(resource_dir, "", .{});
    }
    for (opts.web_resource_files) |res| {
        _ = web.addCopyFile(res.path, res.name);
    }

    return b.addInstallDirectory(.{
        .source_dir = web.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
}

pub fn addServeWebStep(
    owner: *std.Build,
    b: *std.Build,
    name: []const u8,
    web_install: *std.Build.Step.InstallDir,
    host: []const u8,
    port: u16,
) *std.Build.Step.Run {
    const serve_web_exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = owner.path("tools/serve_web.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
        }),
    });
    const serve_web_cmd = b.addRunArtifact(serve_web_exe);
    serve_web_cmd.step.dependOn(&web_install.step);
    serve_web_cmd.addArg(b.getInstallPath(.prefix, "web"));
    serve_web_cmd.addArg(host);
    serve_web_cmd.addArg(b.fmt("{d}", .{port}));
    return serve_web_cmd;
}

/// Builds a `<exe.name>.app` directory under zig-out/bin/ with:
///   Contents/MacOS/<exe>                   -- patched load commands
///   Contents/Frameworks/libMoltenVK.dylib  -- id rewritten to @rpath
///   Contents/Frameworks/libglfw.3.dylib    -- id rewritten to @rpath
///   Contents/Info.plist                    -- minimum viable plist
///   Contents/Resources/<name>              -- opts.resources
///
/// After install, a post-install Run step invokes `codesign --force
/// --sign -` on each leaf dylib, then the exe, then the bundle dir.
/// --deep is intentionally avoided (deprecated, unreliable).
fn macosAppBundle(b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) void {
    const molten_vk_dir = macosMoltenVkPath(b);
    const glfw_dir = macosGlfwPath(b);

    const app_name = b.fmt("{s}.app", .{exe.name});

    // --- patch bundled dylibs: copy into cache, rewrite LC_ID_DYLIB -----
    // Each Run step takes the brew dylib as an input and writes a patched
    // copy to its own cache-managed output path, keeping zig's caching honest.
    const patched_moltenvk = patchDylibId(
        b,
        .{ .cwd_relative = b.pathJoin(&.{ molten_vk_dir, "libMoltenVK.dylib" }) },
        "libMoltenVK.dylib",
    );
    const patched_glfw = patchDylibId(
        b,
        .{ .cwd_relative = b.pathJoin(&.{ glfw_dir, "libglfw.3.dylib" }) },
        "libglfw.3.dylib",
    );

    // --- patch exe load commands ---------------------------------------
    // Xcode 16+ install_name_tool exits non-zero when it invalidates an
    // existing code signature (zig ad-hoc signs arm64 macOS exes), so
    // strip it first. Xcode 16.4 `codesign --remove-signature` leaves
    // __LINKEDIT's filesize pointing past its actual contents, which
    // trips install_name_tool's stricter linkedit check. Use
    // `codesign_allocate -r` -- it removes LC_CODE_SIGNATURE and
    // rewrites __LINKEDIT.filesize/vmsize to match the real extent,
    // which plain `codesign --remove-signature` and `lipo -create` on
    // thin Mach-Os don't do. Fall back to `codesign --remove-signature`
    // for the unsigned case. Post-install `codesign --force --sign -`
    // re-signs.
    const patched_exe = b.addSystemCommand(&.{
        "sh", "-c",
        \\cp "$1" "$2"
        \\chmod +w "$2"
        \\if codesign_allocate -i "$2" -r -o "$2.tmp" 2>/dev/null; then
        \\  mv "$2.tmp" "$2"
        \\else
        \\  rm -f "$2.tmp"
        \\  codesign --remove-signature "$2" 2>/dev/null || true
        \\fi
        \\install_name_tool \
        \\  -change /opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib @rpath/libMoltenVK.dylib \
        \\  -change /opt/homebrew/opt/glfw/lib/libglfw.3.dylib @rpath/libglfw.3.dylib \
        \\  "$2"
        ,
        "sh",
    });
    patched_exe.addArtifactArg(exe);
    const exe_out = patched_exe.addOutputFileArg(exe.name);

    // --- icon: PNG -> .icns via sips + iconutil ------------------------
    const icns_out: ?std.Build.LazyPath = if (opts.icon_png) |png| blk: {
        const gen = b.addSystemCommand(&.{
            "sh", "-c",
            // mktemp a scratch .iconset dir, sips-resize the source PNG into
            // the canonical slot names, then iconutil-pack. Cleanup is
            // best-effort -- on failure the tmpdir leaks, but it's under /tmp.
            \\set -euo pipefail
            \\IN="$1"; OUT="$2"
            \\T=$(mktemp -d -t aether_icns.XXXXXX)
            \\trap 'rm -rf "$T"' EXIT
            \\ISET="$T/AppIcon.iconset"; mkdir -p "$ISET"
            \\for spec in \
            \\  "16 icon_16x16.png" "32 icon_16x16@2x.png" \
            \\  "32 icon_32x32.png" "64 icon_32x32@2x.png" \
            \\  "128 icon_128x128.png" "256 icon_128x128@2x.png" \
            \\  "256 icon_256x256.png" "512 icon_256x256@2x.png" \
            \\  "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
            \\  set -- $spec; sz=$1; name=$2
            \\  sips -z "$sz" "$sz" "$IN" --out "$ISET/$name" >/dev/null
            \\done
            \\iconutil -c icns "$ISET" -o "$OUT"
            ,
            "sh",
        });
        gen.addFileArg(png);
        break :blk gen.addOutputFileArg("AppIcon.icns");
    } else null;

    // --- Info.plist ----------------------------------------------------
    const bundle_id = opts.bundle_id orelse b.fmt("com.aether.{s}", .{exe.name});
    const bundle_name = if (opts.title.len > 0) opts.title else exe.name;
    const icon_key = if (icns_out != null)
        "<key>CFBundleIconFile</key><string>AppIcon</string>"
    else
        "";
    const info_plist = b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\  <key>CFBundleExecutable</key><string>{s}</string>
        \\  <key>CFBundleIdentifier</key><string>{s}</string>
        \\  <key>CFBundleName</key><string>{s}</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>0.0.0</string>
        \\  <key>CFBundleVersion</key><string>0</string>
        \\  <key>LSMinimumSystemVersion</key><string>11.0</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\  {s}
        \\</dict></plist>
        \\
    , .{ exe.name, bundle_id, bundle_name, icon_key });

    // --- assemble the .app tree in a WriteFiles output -----------------
    const app_tree = b.addWriteFiles();
    _ = app_tree.addCopyFile(exe_out, b.fmt("Contents/MacOS/{s}", .{exe.name}));
    _ = app_tree.addCopyFile(patched_moltenvk, "Contents/Frameworks/libMoltenVK.dylib");
    _ = app_tree.addCopyFile(patched_glfw, "Contents/Frameworks/libglfw.3.dylib");
    _ = app_tree.add("Contents/Info.plist", info_plist);
    if (icns_out) |icns| _ = app_tree.addCopyFile(icns, "Contents/Resources/AppIcon.icns");
    for (opts.resources) |res| {
        _ = app_tree.addCopyFile(res.path, b.fmt("Contents/Resources/{s}", .{res.name}));
    }

    // --- install the tree under zig-out/bin/<exe>.app ------------------
    const install = b.addInstallDirectory(.{
        .source_dir = app_tree.getDirectory(),
        .install_dir = .bin,
        .install_subdir = app_name,
    });
    b.getInstallStep().dependOn(&install.step);

    // --- ad-hoc codesign (post-install, operates on zig-out paths) -----
    // Must run AFTER install_name_tool is long done. Sign leaves first,
    // then the exe, then the bundle dir -- avoids --deep which is
    // deprecated and unreliable.
    const bundle_path = b.getInstallPath(.bin, app_name);
    const sign = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
        "codesign --force --sign - \"{s}/Contents/Frameworks/libMoltenVK.dylib\" && " ++
            "codesign --force --sign - \"{s}/Contents/Frameworks/libglfw.3.dylib\" && " ++
            "codesign --force --sign - \"{s}/Contents/MacOS/{s}\" && " ++
            "codesign --force --sign - \"{s}\"",
        .{ bundle_path, bundle_path, bundle_path, exe.name, bundle_path },
    ) });
    sign.step.dependOn(&install.step);
    b.getInstallStep().dependOn(&sign.step);
}

/// Copies a dylib into the build cache and rewrites its LC_ID_DYLIB to
/// `@rpath/<basename>` so it can be loaded from `Contents/Frameworks/`.
fn patchDylibId(b: *std.Build, src: std.Build.LazyPath, basename: []const u8) std.Build.LazyPath {
    // Homebrew dylibs are ad-hoc signed. Xcode 16+ install_name_tool
    // exits non-zero when it invalidates that signature, so strip it
    // first. Xcode 16.4 `codesign --remove-signature` leaves
    // __LINKEDIT's filesize pointing past its real contents (the gap
    // that install_name_tool's stricter linkedit check rejects); use
    // `codesign_allocate -r`, which rewrites __LINKEDIT.filesize/vmsize
    // and truncates. Fall back to `codesign --remove-signature` for
    // the unsigned case. Post-install codesign re-signs.
    const patch = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\cp "$1" "$2"
            \\chmod +w "$2"
            \\if codesign_allocate -i "$2" -r -o "$2.tmp" 2>/dev/null; then
            \\  mv "$2.tmp" "$2"
            \\else
            \\  rm -f "$2.tmp"
            \\  codesign --remove-signature "$2" 2>/dev/null || true
            \\fi
            \\install_name_tool -id @rpath/{s} "$2"
        ,
            .{basename},
        ),
        "sh",
    });
    patch.addFileArg(src);
    return patch.addOutputFileArg(basename);
}

/// Runs the ELF -> PRX -> SFO -> EBOOT.PBP pipeline. Resolves tool
/// artifacts from `psp_dep` but creates all build/install steps on `b`
/// so they register on the downstream project's builder.
fn pspEbootPipeline(b: *std.Build, exe: *std.Build.Step.Compile, psp_dep: *std.Build.Dependency, opts: ExportOptions) pspsdk.PspEboot {
    const mk_prx = b.addRunArtifact(psp_dep.artifact("zPRXGen"));
    mk_prx.addArtifactArg(exe);
    const prx_file = mk_prx.addOutputFileArg("app.prx");

    const mk_sfo = b.addRunArtifact(psp_dep.artifact("zSFOTool"));
    mk_sfo.addArg("write");
    mk_sfo.addArg(opts.title);
    const sfo_file = mk_sfo.addOutputFileArg("PARAM.SFO");

    const pack_pbp = b.addRunArtifact(psp_dep.artifact("zPBPTool"));
    pack_pbp.addArg("pack");
    const eboot_file = pack_pbp.addOutputFileArg("EBOOT.PBP");
    pack_pbp.addFileArg(sfo_file);

    if (opts.icon0) |p| pack_pbp.addFileArg(p) else pack_pbp.addArg("NULL");
    if (opts.icon1) |p| pack_pbp.addFileArg(p) else pack_pbp.addArg("NULL");
    if (opts.pic0) |p| pack_pbp.addFileArg(p) else pack_pbp.addArg("NULL");
    if (opts.pic1) |p| pack_pbp.addFileArg(p) else pack_pbp.addArg("NULL");
    if (opts.snd0) |p| pack_pbp.addFileArg(p) else pack_pbp.addArg("NULL");
    pack_pbp.addFileArg(prx_file);
    pack_pbp.addArg("NULL");

    const result = pspsdk.PspEboot{
        .elf = exe,
        .prx = prx_file,
        .eboot = eboot_file,
    };

    if (opts.output_dir) |dir| {
        const alloc = b.allocator;
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            result.eboot,
            std.mem.concat(alloc, u8, &.{ dir, "/EBOOT.PBP" }) catch @panic("OOM"),
        ).step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            result.prx,
            std.mem.concat(alloc, u8, &.{ dir, "/app.prx" }) catch @panic("OOM"),
        ).step);
        b.getInstallStep().dependOn(&b.addInstallArtifact(result.elf, .{
            .dest_dir = .{ .override = .{ .custom = std.mem.concat(alloc, u8, &.{ "bin/", dir }) catch @panic("OOM") } },
            .dest_sub_path = "app.elf",
        }).step);
    }

    return result;
}

fn nintendo3dsPipeline(owner: *std.Build, b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) void {
    const zitrus_dep = owner.dependency("zitrus", .{});

    b.installArtifact(exe);

    const title = if (opts.title.len > 0) opts.title else exe.name;
    const publisher = if (opts.nintendo_3ds_publisher.len > 0) opts.nintendo_3ds_publisher else "Aether";
    const settings_zon = b.fmt(
        \\.{{
        \\    .titles = .{{
        \\        .english = .{{
        \\            .title = "{s}",
        \\            .description = "{s}",
        \\            .publisher = "{s}",
        \\        }},
        \\    }},
        \\}}
        \\
    , .{ title, title, publisher });

    const write_files = b.addWriteFiles();
    const smdh_settings = write_files.add("aether.smdh.zon", settings_zon);

    const smdh: zitrus.MakeSmdh = .initInner(b, .{
        .tools_artifact = zitrus_dep.artifact("zitrus"),
        .default_icon = zitrus_dep.path("assets/zitrus-logo-smdh.png"),
    }, .{
        .settings = smdh_settings,
        .icon = opts.nintendo_3ds_icon,
    });

    const romfs = if (opts.nintendo_3ds_romfs) |root| blk: {
        const make_romfs: zitrus.MakeRomFs = .initInner(b, .{
            .tools_artifact = zitrus_dep.artifact("zitrus"),
        }, .{
            .name = "romfs.bin",
            .root = root,
        });
        break :blk make_romfs.out;
    } else null;

    const final_3dsx: zitrus.Make3dsx = .initInner(b, .{
        .tools_artifact = zitrus_dep.artifact("zitrus"),
    }, .{
        .name = b.fmt("{s}.3dsx", .{exe.name}),
        .exe = exe,
        .smdh = smdh.out,
        .romfs = romfs,
    });
    final_3dsx.install(b, .{
        .install_dir = .bin,
        .dest_sub_path = if (opts.output_dir) |dir|
            b.fmt("{s}/{s}", .{ dir, final_3dsx.name })
        else
            final_3dsx.name,
    });
}

fn cBackendOptimizeMode(exe: *std.Build.Step.Compile) std.builtin.OptimizeMode {
    return exe.root_module.optimize orelse .Debug;
}

fn cBackendGccOptimizeArg(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe, .ReleaseFast => "-O2",
        .ReleaseSmall => "-Os",
    };
}

fn cBackendGccDebugArg(optimize: std.builtin.OptimizeMode) []const u8 {
    return if (optimize == .Debug or optimize == .ReleaseSafe) "-g" else "-g0";
}

/// Compiles the zig-emitted C with devkitA64, links against libnx, and
/// packages the ELF (plus a NACP and optional RomFS) into a `.nro`
/// homebrew bundle.
fn switchNroPipeline(b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) void {
    // aarch64 GCC supports __int128 natively, so we don't need the
    // `zig.h` integer-alignment patch used by old 32-bit ARM C pipelines.
    // We do still need a compiler_rt object: zig.h calls helpers like
    // `__floatunsisf` / `__floatundidf` / `__floatdisf` unconditionally,
    // but devkitA64's libgcc doesn't ship them — gcc on aarch64 with
    // hardware FP inlines these casts as `ucvtf`/`scvtf`, so the
    // helpers are dead code in normal compilations. Zig's emitted C
    // takes the slow path, so we drop in zig's own compiler_rt to
    // satisfy the references. We localize
    // symbols that overlap newlib (memset/memcpy/...) so the linker
    // pulls newlib's strong implementations.
    const game_target = exe.root_module.resolved_target.?;
    var crt_query = game_target.query;
    crt_query.os_tag = .freestanding;
    crt_query.ofmt = null;
    crt_query.cpu_model = .{ .explicit = game_target.result.cpu.model };
    const crt_target = b.resolveTargetQuery(crt_query);

    const compiler_rt_path = b.pathJoin(&.{
        b.graph.zig_lib_directory.path orelse ".",
        "compiler_rt.zig",
    });
    const crt_obj = b.addObject(.{
        .name = "aether_switch_compiler_rt",
        .root_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = compiler_rt_path },
            .target = crt_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            // Switch homebrew uses libnx's switch.specs which links
            // with `-z text`. PIC is mandatory for any object that
            // ends up in the read-only .text segment, otherwise the
            // linker rejects the dynamic absolute relocations.
            .pic = true,
        }),
    });

    const dkp = devkitProPath(b);

    const strip_libc = b.addSystemCommand(&.{
        b.pathJoin(&.{ dkp, "devkitA64/bin/aarch64-none-elf-objcopy" }),
        "--localize-symbol=memset",
        "--localize-symbol=memcpy",
        "--localize-symbol=memmove",
        "--localize-symbol=memcmp",
        "--localize-symbol=strlen",
        "--localize-symbol=bcmp",
    });
    strip_libc.addArtifactArg(crt_obj);
    const crt_clean = strip_libc.addOutputFileArg("aether_switch_compiler_rt.o");
    const gcc = b.pathJoin(&.{ dkp, "devkitA64/bin/aarch64-none-elf-gcc" });
    const tool_elf2nro = b.pathJoin(&.{ dkp, "tools/bin/elf2nro" });
    const tool_nacp = b.pathJoin(&.{ dkp, "tools/bin/nacptool" });
    const libnx_inc = b.pathJoin(&.{ dkp, "libnx/include" });
    const libnx_lib = b.pathJoin(&.{ dkp, "libnx/lib" });
    const libnx_specs = b.pathJoin(&.{ dkp, "libnx/switch.specs" });
    const default_icon = b.pathJoin(&.{ dkp, "libnx/default_icon.jpg" });

    const syms_wf = b.addWriteFiles();
    const text_syms_ld = syms_wf.add("aether_switch_text_syms.ld",
        \\/* Zig C backend (for Switch ofmt=c) mangles extern names with zig_e_ prefix. */
        \\zig_e___text_start = ADDR(.text);
        \\zig_e___text_end = ADDR(.text) + SIZEOF(.text);
        \\__text_start = zig_e___text_start;
        \\__text_end = zig_e___text_end;
    );

    // Standard Switch arch flags from devkitPro's switch_rules /
    // example Makefiles. `-mtp=soft` matches what libnx is built
    // against; mismatching the TLS access mode crashes on the first
    // thread-local read.
    const arch = [_][]const u8{
        "-march=armv8-a+crc+crypto", "-mtune=cortex-a57", "-mtp=soft", "-fPIE", "-fno-omit-frame-pointer",
    };

    const exe_optimize = cBackendOptimizeMode(exe);

    const link = b.addSystemCommand(&.{gcc});
    link.addArgs(&arch);
    link.addArgs(&.{
        "-ffunction-sections",
        "-fdata-sections",
        "-D_FORTIFY_SOURCE=0",
        "-D__SWITCH__",
        cBackendGccOptimizeArg(exe_optimize),
        cBackendGccDebugArg(exe_optimize),
        b.fmt("-specs={s}", .{libnx_specs}),
        "-T",
        // Pin the C standard to C11 (zig.h targets `_Noreturn`, not
        // C23's `[[noreturn]]`).
    });
    link.addFileArg(text_syms_ld);
    link.addArgs(&.{
        "-std=gnu11",
        // zig's -ofmt=c emitter has known pointer/int-conversion
        // mismatches that gcc 14+ promotes to errors. We don't author
        // the C, so demote them.
        "-fno-strict-aliasing",
        "-Wno-incompatible-pointer-types",
        "-Wno-int-conversion",
        "-Wno-builtin-declaration-mismatch",
    });
    link.addArg(b.fmt("-I{s}", .{libnx_inc}));
    // zig's emitted C `#include "zig.h"`. The header lives in zig's
    // own lib directory; point gcc at it. aarch64 GCC's __int128
    // alignment matches zig's, so no patching is needed.
    link.addArg(b.fmt("-I{s}", .{b.graph.zig_lib_directory.path orelse "."}));
    link.addArg("-x");
    link.addArg("c");
    link.addArtifactArg(exe);
    link.addArg("-x");
    link.addArg("none");
    link.addFileArg(crt_clean);
    link.addArg(b.fmt("-L{s}", .{libnx_lib}));
    link.addArgs(&.{ "-ldeko3d", "-lnx", "-lm" });
    link.addArg("-o");
    const elf = link.addOutputFileArg(b.fmt("{s}.elf", .{exe.name}));

    // NACP metadata (HOME-menu title, author, version).
    const nacp_run = b.addSystemCommand(&.{ tool_nacp, "--create" });
    nacp_run.addArg(if (opts.title.len > 0) opts.title else exe.name);
    nacp_run.addArg(if (opts.switch_author.len > 0) opts.switch_author else "Aether");
    nacp_run.addArg(if (opts.switch_version.len > 0) opts.switch_version else "1.0.0");
    const nacp = nacp_run.addOutputFileArg(b.fmt("{s}.nacp", .{exe.name}));

    // ELF -> NRO. The icon, NACP, and (optional) romfs ride in via
    // flag-form args.
    const pack = b.addSystemCommand(&.{tool_elf2nro});
    pack.addFileArg(elf);
    const nro = pack.addOutputFileArg(b.fmt("{s}.nro", .{exe.name}));
    if (opts.switch_icon) |icon|
        pack.addPrefixedFileArg("--icon=", icon)
    else
        pack.addArg(b.fmt("--icon={s}", .{default_icon}));
    pack.addPrefixedFileArg("--nacp=", nacp);
    if (opts.switch_romfs) |r| pack.addPrefixedDirectoryArg("--romfsdir=", r);

    if (opts.output_dir) |dir| {
        const alloc = b.allocator;
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            nro,
            std.mem.concat(alloc, u8, &.{ dir, "/", exe.name, ".nro" }) catch @panic("OOM"),
        ).step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            elf,
            std.mem.concat(alloc, u8, &.{ dir, "/", exe.name, ".elf" }) catch @panic("OOM"),
        ).step);
    } else {
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            nro,
            b.fmt("{s}.nro", .{exe.name}),
        ).step);
    }
}

// --- Aether's own build (test app + engine tests) ---

fn makeResourceManifest(b: *std.Build, resource_dir_path: []const u8) []const u8 {
    const io = b.graph.io;
    const full_resource_dir_path = b.pathFromRoot(resource_dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, full_resource_dir_path, .{ .iterate = true }) catch |err| {
        std.debug.panic("unable to open web resource directory '{s}': {s}", .{ resource_dir_path, @errorName(err) });
    };
    defer dir.close(io);

    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();

    var manifest: std.ArrayList(u8) = .empty;
    while (walker.next(io) catch |err| {
        std.debug.panic("unable to walk web resource directory '{s}': {s}", .{ resource_dir_path, @errorName(err) });
    }) |entry| {
        if (entry.kind != .file) continue;
        if (std.mem.eql(u8, entry.path, "resources.manifest")) continue;
        manifest.appendSlice(b.allocator, entry.path) catch @panic("OOM");
        manifest.append(b.allocator, '\n') catch @panic("OOM");
    }
    return manifest.toOwnedSlice(b.allocator) catch @panic("OOM");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const web_resources_path = b.option([]const u8, "web-resources", "WASM/browser: directory to copy into zig-out/web and preload via resources.manifest (default: test)") orelse "test";
    const web_host = b.option([]const u8, "web-host", "serve-web: bind host (default: 127.0.0.1)") orelse "127.0.0.1";
    const web_port = b.option(u16, "web-port", "serve-web: bind port (default: 8080)") orelse 8080;

    const overrides: Config.Overrides = .{
        .gfx = b.option(Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
        .audio = b.option(Audio, "audio", "Audio backend override (default: platform default)"),
        .psp_display_mode = b.option(PspDisplayMode, "psp-display", "PSP display mode: rgba8888 (32-bit, default) or rgb565 (16-bit)"),
        .psp_mipmaps = b.option(bool, "psp-mipmaps", "PSP: generate mip levels for VRAM-resident textures (default: false)"),
        .use_cwd = b.option(bool, "use-cwd", "Force resources+data dirs to CWD (debug/CI convenience; default: false)"),
        .flush_logs = b.option(bool, "flush-logs", "Flush aether.log after every log message (debugging hard hangs; default: false)"),
        .nintendo_switch = b.option(bool, "nintendo-switch", "Build for Nintendo Switch (requires -Dtarget=aarch64-freestanding-none and devkitA64/libnx)"),
    };

    const config = Config.resolve(target, overrides);

    const exe = addGame(b, b, .{
        .name = "Aether",
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });

    const nintendo_romfs = b.addWriteFiles();
    _ = nintendo_romfs.addCopyFile(b.path("test/test.png"), "test.png");
    _ = nintendo_romfs.addCopyFile(b.path("test/calm1.wav"), "calm1.wav");
    _ = nintendo_romfs.addCopyFile(b.path("test/grass1.wav"), "grass1.wav");

    exportArtifact(b, b, exe, config, .{
        .title = "Aether",
        .output_dir = switch (config.platform) {
            .psp => "Aether-PSP",
            .nintendo_3ds => "Aether-3DS",
            .nintendo_switch => "Aether-Switch",
            else => null,
        },
        .resources = &.{
            .{ .path = b.path("test/test.png"), .name = "test.png" },
            .{ .path = b.path("test/calm1.wav"), .name = "calm1.wav" },
            .{ .path = b.path("test/grass1.wav"), .name = "grass1.wav" },
        },
        .nintendo_3ds_romfs = if (config.platform == .nintendo_3ds) nintendo_romfs.getDirectory() else null,
        .switch_romfs = if (config.platform == .nintendo_switch) nintendo_romfs.getDirectory() else null,
    });

    const web_target = webTarget(b);
    const web_overrides: Config.Overrides = .{
        .gfx = .webgl,
        .use_cwd = true,
    };
    const web_exe = addGame(b, b, .{
        .name = "Aether",
        .root_source_file = b.path("test/web_main.zig"),
        .target = web_target,
        .optimize = optimize,
        .overrides = web_overrides,
    });
    const web_install = addWebBundle(b, b, web_exe, .{
        .web_resources = b.path(web_resources_path),
        .web_resource_manifest = makeResourceManifest(b, web_resources_path),
    });

    const web_step = b.step("web", "Build the browser-playable WASM site in zig-out/web");
    web_step.dependOn(&web_install.step);

    const serve_web_cmd = addServeWebStep(b, b, "aether-serve-web", web_install, web_host, web_port);

    const serve_web_step = b.step("serve-web", "Serve zig-out/web with WASM MIME and COOP/COEP headers");
    serve_web_step.dependOn(&serve_web_cmd.step);

    const run_step = b.step("run", "Run the app");
    if (config.platform == .nintendo_switch) {
        // Switch can't run natively on the host. nxlink pushes the
        // .nro to nx-hbloader on a networked Switch (mDNS by default,
        // explicit IP via -a).
        const dkp = devkitProPath(b);
        const link_cmd = b.addSystemCommand(&.{b.pathJoin(&.{ dkp, "tools/bin/nxlink" })});
        if (b.option([]const u8, "nxlink-address", "Switch: target IP for nxlink push (default: mDNS auto-discover)")) |ip| {
            link_cmd.addArgs(&.{ "-a", ip });
        }
        if (b.option(u32, "nxlink-retries", "Switch: nxlink retry count (default: 10)")) |n| {
            link_cmd.addArgs(&.{ "-r", b.fmt("{d}", .{n}) });
        }
        if (b.option(bool, "nxlink-server", "Switch: pass -s so nxlink stays listening after upload (relays stdout/stderr from nro)") orelse false) {
            link_cmd.addArg("-s");
        }
        link_cmd.addArg(b.getInstallPath(.bin, "Aether-Switch/Aether.nro"));
        link_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            // nxlink takes nro args after a `--args` separator.
            link_cmd.addArg("--args");
            link_cmd.addArgs(args);
        }

        const link_step = b.step("nxlink", "Push the nro to a networked Switch via nxlink");
        link_step.dependOn(&link_cmd.step);

        // `zig build run` aliases to nxlink for Switch so the same
        // command works across host/PSP/Switch workflows.
        run_step.dependOn(&link_cmd.step);
    } else if (config.platform == .nintendo_3ds) {
        const dkp = devkitProPath(b);
        const link_cmd = b.addSystemCommand(&.{b.pathJoin(&.{ dkp, "tools/bin/3dslink" })});
        if (b.option([]const u8, "3dslink-address", "3DS: target IP/hostname for 3dslink push (default: broadcast discovery)")) |ip| {
            link_cmd.addArgs(&.{ "-a", ip });
        }
        if (b.option(u32, "3dslink-retries", "3DS: 3dslink retry count")) |n| {
            link_cmd.addArgs(&.{ "-r", b.fmt("{d}", .{n}) });
        }
        if (b.option(bool, "3dslink-server", "3DS: pass -s so 3dslink stays listening after upload") orelse false) {
            link_cmd.addArg("-s");
        }
        link_cmd.addArg(b.getInstallPath(.bin, "Aether-3DS/Aether.3dsx"));
        link_cmd.step.dependOn(b.getInstallStep());

        const link_step = b.step("3dslink", "Push the 3dsx to a networked 3DS via 3dslink");
        link_step.dependOn(&link_cmd.step);

        run_step.dependOn(&link_cmd.step);
    } else {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    // Engine unit tests (desktop only -- PSP/3DS/Switch pull in symbols
    // that can't be linked or analyzed under the test runner)
    if (config.platform != .psp and config.platform != .nintendo_3ds and config.platform != .nintendo_switch) {
        const mod_tests = b.addTest(.{
            .root_module = exe.root_module.import_table.get("aether").?,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
    }
}
