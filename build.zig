const std = @import("std");
const pspsdk = @import("pspsdk");

const DEFAULT_3DS_HEAP_SIZE: u32 = 4 * 1024 * 1024;
const DEFAULT_3DS_LINEAR_HEAP_SIZE: u32 = 60 * 1024 * 1024;

pub const Platform = enum {
    windows,
    linux,
    macos,
    psp,
    /// Nintendo 3DS. Builtin os tag is `.@"3ds"`, but the Zig options
    /// serializer can't emit `.@"3ds"` as an enum value literal, so the
    /// internal Aether tag uses a leading-letter form.
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
    /// 3DS: small regular heap reserved for libctru/newlib internals.
    nintendo_3ds_heap_size: u32 = DEFAULT_3DS_HEAP_SIZE,
    /// 3DS: linear heap used by Aether's process allocator and GPU uploads.
    nintendo_3ds_linear_heap_size: u32 = DEFAULT_3DS_LINEAR_HEAP_SIZE,
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
            else => .default,
        };

        const default_audio: Audio = .default;

        return .{
            .platform = plat,
            .gfx = overrides.gfx orelse default_gfx,
            .audio = overrides.audio orelse default_audio,
            .psp_display_mode = overrides.psp_display_mode orelse .rgba8888,
            .psp_mipmaps = overrides.psp_mipmaps orelse false,
            .nintendo_3ds_heap_size = overrides.nintendo_3ds_heap_size orelse DEFAULT_3DS_HEAP_SIZE,
            .nintendo_3ds_linear_heap_size = overrides.nintendo_3ds_linear_heap_size orelse DEFAULT_3DS_LINEAR_HEAP_SIZE,
            .use_cwd = overrides.use_cwd orelse false,
        };
    }

    pub const Overrides = struct {
        gfx: ?Gfx = null,
        audio: ?Audio = null,
        psp_display_mode: ?PspDisplayMode = null,
        psp_mipmaps: ?bool = null,
        nintendo_3ds_heap_size: ?u32 = null,
        nintendo_3ds_linear_heap_size: ?u32 = null,
        use_cwd: ?bool = null,
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
    const opt = b.option([]const u8, "devkitpro-path", "3DS: devkitPro install root (default: $DEVKITPRO or /opt/devkitpro)");
    const p = opt orelse b.graph.environ_map.get("DEVKITPRO") orelse "/opt/devkitpro";
    devkitpro_path_cached = p;
    return p;
}

fn addNintendoCImportPaths(owner: *std.Build, mod: *std.Build.Module, config: Config, dkp: []const u8) void {
    const b = mod.owner;
    mod.addIncludePath(owner.path("src/platform"));
    switch (config.platform) {
        .nintendo_3ds => {
            // Keep newlib before libctru so libctru's include_next sys wrappers
            // resolve during Zig's C translation of Citro3D/libctru headers.
            mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dkp, "devkitARM/arm-none-eabi/include" }) });
            mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dkp, "libctru/include" }) });
        },
        .nintendo_switch => {
            mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dkp, "devkitA64/aarch64-none-elf/include" }) });
            mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ dkp, "libnx/include" }) });
        },
        else => {},
    }
}

/// Creates a `3dslink` command for pushing an installed `.3dsx` to a
/// networked 3DS. Reuses Aether's devkitPro option/cache so downstream
/// builds do not need to redeclare `-Ddevkitpro-path`.
pub fn add3dslink(b: *std.Build, threedsx_path: []const u8) *std.Build.Step.Run {
    const dkp = devkitProPath(b);
    const link_cmd = b.addSystemCommand(&.{b.pathJoin(&.{ dkp, "tools/bin/3dslink" })});
    if (b.option([]const u8, "3dslink-address", "3DS: target IP for 3dslink push (default: mDNS auto-discover)")) |ip| {
        link_cmd.addArgs(&.{ "-a", ip });
    }
    if (b.option(u32, "3dslink-retries", "3DS: 3dslink retry count (default: 10)")) |n| {
        link_cmd.addArgs(&.{ "-r", b.fmt("{d}", .{n}) });
    }
    if (b.option(bool, "3dslink-server", "3DS: pass -s so 3dslink stays listening after the upload (useful for some Rosalina versions and for stdout relay)") orelse false) {
        link_cmd.addArg("-s");
    }
    link_cmd.addArg(threedsx_path);
    link_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| link_cmd.addArgs(args);
    return link_cmd;
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
    const uses_nintendo_c_io = config.platform == .nintendo_3ds or config.platform == .nintendo_switch;

    // 3DS and Switch force ofmt=c — there's no Zig-native backend for
    // either Horizon target yet, so we emit C and let an external
    // toolchain (devkitARM/libctru on 3DS, devkitA64/libnx on Switch)
    // compile the result.
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

    if (psp_dep) |pd| {
        mod.addImport("pspsdk", pd.module("pspsdk"));
    } else if (config.platform == .nintendo_3ds or config.platform == .nintendo_switch) {
        // Console SDK symbols are declared as backend-local externs and
        // resolved by the export pipeline's devkitPro link step.
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

    const root_mod = if (uses_nintendo_c_io) b.createModule(.{
        .root_source_file = owner.path(switch (config.platform) {
            .nintendo_3ds => "src/platform/3ds/services.zig",
            .nintendo_switch => "src/platform/switch/services.zig",
            else => unreachable,
        }),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
            .{ .name = "options", .module = options_module },
        },
    }) else user_mod;

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = root_mod,
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

    if (config.platform == .windows and (opts.optimize == .ReleaseFast or opts.optimize == .ReleaseSmall)) {
        exe.subsystem = .windows;
    }

    if (uses_nintendo_c_io) {
        // The platform shim exports C `main` itself. Keeping std/start's
        // libc main wrapper disabled avoids pulling in unsupported
        // freestanding libc/thread startup paths while still preserving the
        // exported shim in the emitted C.
        exe.entry = .disabled;
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
    const uses_nintendo_c_io = config.platform == .nintendo_3ds or config.platform == .nintendo_switch;

    // 3DS and Switch force ofmt=c (see addGame for details).
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

    if (psp_dep) |pd| {
        mod.addImport("pspsdk", pd.module("pspsdk"));
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

    const root_mod = if (uses_nintendo_c_io) b.createModule(.{
        .root_source_file = owner.path(switch (config.platform) {
            .nintendo_3ds => "src/platform/3ds/services.zig",
            .nintendo_switch => "src/platform/switch/services.zig",
            else => unreachable,
        }),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
            .{ .name = "options", .module = options_module },
        },
    }) else user_mod;

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = root_mod,
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

    if (uses_nintendo_c_io) {
        exe.entry = .disabled;
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

fn addUamStep(b: *std.Build, uam: []const u8, stage: []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ uam, "-s", stage, "-o" });
    const output = run.addOutputFileArg(output_name);
    run.addFileArg(input);
    return output;
}

fn addPicassoStep(b: *std.Build, picasso: []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ picasso, "-o" });
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
    if (config.platform == .nintendo_3ds and config.gfx == .default) {
        const picasso = b.pathJoin(&.{ devkitProPath(b), "tools/bin/picasso" });
        const vert = addPicassoStep(
            b,
            picasso,
            "basic.shbin",
            owner.path("src/platform/3ds/shaders/basic.v.pica"),
        );
        const files = b.addWriteFiles();
        const frag = files.add("basic.frag.stub", "");
        return .{ .vert = vert, .frag = frag };
    }

    if (config.platform == .nintendo_switch and config.gfx == .default) {
        const uam = b.pathJoin(&.{ devkitProPath(b), "tools/bin/uam" });
        return .{
            .vert = addUamStep(
                b,
                uam,
                "vert",
                "basic.vert.dksh",
                owner.path("src/platform/switch/shaders/basic.vert.glsl"),
            ),
            .frag = addUamStep(
                b,
                uam,
                "frag",
                "basic.frag.dksh",
                owner.path("src/platform/switch/shaders/basic.frag.glsl"),
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
    /// alongside the exe in `zig-out/bin/`. Ignored on PSP and 3DS.
    resources: []const Resource = &.{},
    /// 3DS: SMDH long description (the second line shown in the HOME
    /// menu detail panel). Falls back to "Built with Aether" when empty.
    smdh_long_description: []const u8 = "",
    /// 3DS: SMDH author string. Empty leaves the field blank.
    smdh_author: []const u8 = "",
    /// 3DS: 48x48 PNG icon embedded in the SMDH. When null, libctru's
    /// `default_icon.png` is used.
    smdh_icon: ?std.Build.LazyPath = null,
    /// 3DS: directory (or pre-built `.romfs`) embedded into the 3DSX.
    romfs: ?std.Build.LazyPath = null,
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
        threedsxPipeline(b, exe, opts);
    } else if (config.platform == .nintendo_switch) {
        switchNroPipeline(b, exe, opts);
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

fn patch3dsGeneratedC(b: *std.Build, exe: *std.Build.Step.Compile) std.Build.LazyPath {
    const patch = b.addSystemCommand(&.{
        "perl", "-e",
        \\local $/;
        \\my $src = <>;
        \\my %align16 = ();
        \\while ($src =~ /zig_static_assert\(_Alignof \(struct ([A-Za-z0-9_]+)\) == 16,/g) {
        \\    $align16{$1} = 1;
        \\}
        \\my $pending = "";
        \\for my $line (split /(?<=\n)/, $src) {
        \\    if ($pending ne "") {
        \\        if ($line =~ s/^};/} __attribute__((aligned(16)));/) {
        \\            $pending = "";
        \\        }
        \\    } elsif ($line =~ /^struct\s+([A-Za-z0-9_]+)\s*\{/) {
        \\        my $name = $1;
        \\        if ($align16{$name}) {
        \\            if ($line !~ s/\};/} __attribute__((aligned(16)));/) {
        \\                $pending = $name;
        \\            }
        \\        }
        \\    }
        \\    print $line;
        \\}
    });
    patch.addArtifactArg(exe);
    return patch.captureStdOut(.{ .basename = b.fmt("{s}.3ds.c", .{exe.name}) });
}

/// Compiles the zig-emitted C with devkitARM, links against libctru, and
/// packages the ELF (plus an SMDH and optional RomFS) into a `.3dsx`
/// homebrew bundle. Mirrors `pspEbootPipeline` for the PSP toolchain.
fn threedsxPipeline(b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) void {
    // Derive a sibling target for compiler_rt: same cpu/abi/endianness
    // as the game (so the calling conventions and float ABI match
    // libctru), but os=freestanding (sidesteps the 3DS-specific posix
    // dependencies in std) and the default object format (so this
    // module compiles natively to an ELF object the gcc driver can
    // consume, rather than .c). devkitARM's libgcc.a doesn't ship the
    // 128-bit-int compiler-rt entry points (`__multi3`/`__divti3`/etc.),
    // so we provide them ourselves from zig's compiler_rt.
    const game_target = exe.root_module.resolved_target.?;
    var crt_query = game_target.query;
    crt_query.os_tag = .freestanding;
    crt_query.ofmt = null;
    // Explicitly pin the cpu model to whatever the game target
    // resolved to (arm.mpcore for the 3DS). Without this, swapping
    // os_tag to .freestanding loses the os-derived cpu choice and
    // zig falls back to a generic baseline that emits ARMv6T2+
    // instructions (e.g. `mls`) the ARMv6K MPCore doesn't decode —
    // crashes show up as "undefined instruction" in compiler_rt
    // helpers like `__udivmodsi4`.
    crt_query.cpu_model = .{ .explicit = game_target.result.cpu.model };
    const crt_target = b.resolveTargetQuery(crt_query);

    const compiler_rt_path = b.pathJoin(&.{
        b.graph.zig_lib_directory.path orelse ".",
        "compiler_rt.zig",
    });
    const crt_obj = b.addObject(.{
        .name = "aether_3ds_compiler_rt",
        .root_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = compiler_rt_path },
            .target = crt_target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });

    const dkp = devkitProPath(b);

    // Strip the libc-overlap symbols from the compiler_rt object.
    // zig's compiler_rt re-exports `memset`/`memcpy`/`memmove` and
    // their `__aeabi_*` shims as WEAK; the `__aeabi_memset` and
    // `memset` versions form a recursive `bl` cycle that blows the
    // stack on 32-bit ARM. Newlib has real implementations, but the
    // linker won't reach for them while compiler_rt's weak version
    // already resolves the reference. `--strip-symbol` drops the
    // exports so the references stay unresolved at compiler_rt and
    // the linker pulls newlib's strong implementations from libc.a.
    const strip_libc = b.addSystemCommand(&.{
        b.pathJoin(&.{ dkp, "devkitARM/bin/arm-none-eabi-objcopy" }),
        "--localize-symbol=memset",
        "--localize-symbol=memcpy",
        "--localize-symbol=memmove",
        "--localize-symbol=memcmp",
        "--localize-symbol=__memset",
        "--localize-symbol=__memcpy",
        "--localize-symbol=__memmove",
        "--localize-symbol=__memcpy_chk",
        "--localize-symbol=__aeabi_memset",
        "--localize-symbol=__aeabi_memset4",
        "--localize-symbol=__aeabi_memset8",
        "--localize-symbol=__aeabi_memcpy",
        "--localize-symbol=__aeabi_memcpy4",
        "--localize-symbol=__aeabi_memcpy8",
        "--localize-symbol=__aeabi_memmove",
        "--localize-symbol=__aeabi_memmove4",
        "--localize-symbol=__aeabi_memmove8",
        "--localize-symbol=strlen",
        "--localize-symbol=bcmp",
    });
    strip_libc.addArtifactArg(crt_obj);
    const crt_clean = strip_libc.addOutputFileArg("aether_3ds_compiler_rt.o");
    const gcc = b.pathJoin(&.{ dkp, "devkitARM/bin/arm-none-eabi-gcc" });
    const tool_3dsx = b.pathJoin(&.{ dkp, "tools/bin/3dsxtool" });
    const tool_smdh = b.pathJoin(&.{ dkp, "tools/bin/smdhtool" });
    const ctru_inc = b.pathJoin(&.{ dkp, "libctru/include" });
    const ctru_lib = b.pathJoin(&.{ dkp, "libctru/lib" });
    const default_icon = b.pathJoin(&.{ dkp, "libctru/default_icon.png" });
    const zig_h_src = b.pathJoin(&.{ b.graph.zig_lib_directory.path orelse ".", "zig.h" });

    // zig.h hardcodes `zig_align(16)` for its `zig_i128`/`zig_u128`
    // struct fallback (used when `__int128` isn't supported by the C
    // compiler -- gcc on 32-bit ARM is one such target). Zig's ARM
    // layout uses 8-byte alignment for those integer types, while f128
    // still needs 16-byte alignment. Patch only the integer fallback
    // typedefs, then route unsupported ARM f128 through zig.h's vector
    // fallback with explicit 16-byte alignment.
    const patch = b.addSystemCommand(&.{"perl"});
    patch.addArgs(&.{
        "-0pe",
        \\s/typedef struct \{ zig_align\(16\) uint64_t lo; uint64_t hi; \} zig_u128;/typedef struct { zig_align(8) uint64_t lo; uint64_t hi; } zig_u128;/g;
        \\s/typedef struct \{ zig_align\(16\) uint64_t lo;  int64_t hi; \} zig_i128;/typedef struct { zig_align(8) uint64_t lo;  int64_t hi; } zig_i128;/g;
        \\s/typedef struct \{ zig_align\(16\) uint64_t hi; uint64_t lo; \} zig_u128;/typedef struct { zig_align(8) uint64_t hi; uint64_t lo; } zig_u128;/g;
        \\s/typedef struct \{ zig_align\(16\)  int64_t hi; uint64_t lo; \} zig_i128;/typedef struct { zig_align(8)  int64_t hi; uint64_t lo; } zig_i128;/g;
        \\s/#if defined\(zig_darwin\) \|\| defined\(zig_aarch64\)/#if defined(zig_darwin) || defined(zig_aarch64) || defined(zig_arm)/;
        \\s/typedef __attribute__\(\(__vector_size__\(2 \* sizeof\(uint64_t\)\)\)\) uint64_t zig_v2u64;/typedef __attribute__((__vector_size__(2 * sizeof(uint64_t)), aligned(16))) uint64_t zig_v2u64;/;
    });
    patch.addFileArg(.{ .cwd_relative = zig_h_src });
    const patched_zig_h = patch.captureStdOut(.{ .basename = "zig.h" });

    const include_wf = b.addWriteFiles();
    _ = include_wf.addCopyFile(patched_zig_h, "zig.h");

    const shim_wf = b.addWriteFiles();
    const exception_shim = shim_wf.add("aether_3ds_exception.c",
        \\#include <3ds.h>
        \\
        \\extern void aether3dsExceptionHandler(ERRF_ExceptionInfo *excep, CpuRegisters *regs);
        \\
        \\void aether3dsInstallExceptionHandler(void *stack_top) {
        \\    threadOnException(aether3dsExceptionHandler, stack_top, WRITE_DATA_TO_HANDLER_STACK);
        \\}
        \\
    );

    // Small linker script fragment providing accurate .text bounds as
    // link-time constants. This lets the panic unwinder in services.zig
    // use real section start/end (via ADDR/SIZEOF) instead of any
    // hardcoded/sketchy ranges for isLikelyReturnAddress text checks.
    const syms_wf = b.addWriteFiles();
    const text_syms_ld = syms_wf.add("aether_3ds_text_syms.ld",
        \\/* Zig C backend (for 3DS ofmt=c) mangles extern names with zig_e_ prefix. */
        \\/* Provide both for the isLikelyReturnAddress range checks + any debug. */
        \\zig_e___text_start = ADDR(.text);
        \\zig_e___text_end = ADDR(.text) + SIZEOF(.text);
        \\__text_start = zig_e___text_start;
        \\__text_end = zig_e___text_end;
    );

    // Standard 3DS arch flags from devkitPro's template Makefile.
    const arch = [_][]const u8{
        "-march=armv6k",           "-mtune=mpcore", "-mfloat-abi=hard", "-mtp=soft",
        // Keep frame pointers so manual r11-based stack walk in panic handler
        // can produce useful unwind (otherwise gcc -O* uses r11 as temp and
        // chains are absent or clobbered, leading to data aborts in the walker).
        "-fno-omit-frame-pointer",
    };

    // Single-shot compile + link via the gcc driver. 3dsx.specs pulls
    // in `_3dsx_crt0` (which calls our exported `main`) and the 3DSX
    // linker script. We also supply a tiny -T fragment for accurate
    // __text_* symbols (see text_syms_ld above).
    const link = b.addSystemCommand(&.{gcc});
    link.addArgs(&arch);
    link.addArgs(&.{
        "-mword-relocations",
        "-ffunction-sections",
        "-D__3DS__",
        "-DARM11",
        if (exe.root_module.optimize != .Debug or exe.root_module.optimize == .ReleaseSmall) "-O2" else if (exe.root_module.optimize == .ReleaseSmall) "-Os" else "-O0",
        if (exe.root_module.optimize == .Debug or exe.root_module.optimize == .ReleaseSafe) "-g" else "-g0",
        "-specs=3dsx.specs",
        "-T",
    });
    link.addFileArg(text_syms_ld);
    link.addArgs(&.{
        "-Wl,--wrap=threadCreate",
        "-Wl,--no-warn-execstack",
    });
    link.addArgs(&.{
        // Pin the C standard to C11. zig.h picks `[[noreturn]]` under
        // C23 but emits it in attribute-list position that gcc rejects;
        // C11's `_Noreturn` is what zig's emitter actually targets.
        "-std=gnu11",
    });
    link.addArgs(&.{
        // zig's -ofmt=c emitter treats `uintptr_t` and `uint32_t` as
        // interchangeable on 32-bit ARM (they ARE the same width) but
        // gcc 14+ promotes the resulting pointer-type mismatch from a
        // warning to an error. Demote it and a couple of related
        // chatters; we don't author this C and there's nothing
        // actionable in the warnings.
        "-Wno-incompatible-pointer-types",
        "-Wno-int-conversion",
        "-Wno-builtin-declaration-mismatch",
    });
    link.addArg(b.fmt("-I{s}", .{ctru_inc}));
    link.addPrefixedDirectoryArg("-I", include_wf.getDirectory());
    link.addArg("-x");
    link.addArg("c");
    link.addFileArg(patch3dsGeneratedC(b, exe));
    link.addFileArg(exception_shim);
    // Reset language so gcc treats subsequent inputs by extension; the
    // compiler_rt object is ELF arm and `-x c` would mis-parse it.
    link.addArg("-x");
    link.addArg("none");
    link.addFileArg(crt_clean);
    link.addArg(b.fmt("-L{s}", .{ctru_lib}));
    link.addArgs(&.{ "-lcitro3d", "-lctru", "-lm" });
    link.addArg("-o");
    const elf = link.addOutputFileArg(b.fmt("{s}.elf", .{exe.name}));

    // SMDH metadata (HOME-menu name, description, author, icon).
    const smdh_run = b.addSystemCommand(&.{ tool_smdh, "--create" });
    smdh_run.addArg(if (opts.title.len > 0) opts.title else exe.name);
    smdh_run.addArg(if (opts.smdh_long_description.len > 0)
        opts.smdh_long_description
    else
        "Built with Aether");
    smdh_run.addArg(opts.smdh_author);
    if (opts.smdh_icon) |icon|
        smdh_run.addFileArg(icon)
    else
        smdh_run.addArg(default_icon);
    const smdh = smdh_run.addOutputFileArg(b.fmt("{s}.smdh", .{exe.name}));

    // ELF -> 3DSX. The smdh and (optional) romfs ride in via the
    // `--smdh=` / `--romfs=` flag-form args.
    const pack = b.addSystemCommand(&.{tool_3dsx});
    pack.addFileArg(elf);
    const threedsx = pack.addOutputFileArg(b.fmt("{s}.3dsx", .{exe.name}));
    pack.addPrefixedFileArg("--smdh=", smdh);
    if (opts.romfs) |r| pack.addPrefixedDirectoryArg("--romfs=", r);

    if (opts.output_dir) |dir| {
        const alloc = b.allocator;
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            threedsx,
            std.mem.concat(alloc, u8, &.{ dir, "/", exe.name, ".3dsx" }) catch @panic("OOM"),
        ).step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            elf,
            std.mem.concat(alloc, u8, &.{ dir, "/", exe.name, ".elf" }) catch @panic("OOM"),
        ).step);
    } else {
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            threedsx,
            b.fmt("{s}.3dsx", .{exe.name}),
        ).step);
    }
}

/// Compiles the zig-emitted C with devkitA64, links against libnx, and
/// packages the ELF (plus a NACP and optional RomFS) into a `.nro`
/// homebrew bundle. Mirrors `threedsxPipeline` for the Switch toolchain.
fn switchNroPipeline(b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) void {
    // aarch64 GCC supports __int128 natively, so we don't need the
    // `zig.h` align(16) -> align(8) patch the 3DS pipeline applies.
    //
    // We do still need a compiler_rt object: zig.h calls helpers like
    // `__floatunsisf` / `__floatundidf` / `__floatdisf` unconditionally,
    // but devkitA64's libgcc doesn't ship them — gcc on aarch64 with
    // hardware FP inlines these casts as `ucvtf`/`scvtf`, so the
    // helpers are dead code in normal compilations. Zig's emitted C
    // takes the slow path, so we drop in zig's own compiler_rt to
    // satisfy the references. Like the 3DS pipeline we localize
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

    // Standard Switch arch flags from devkitPro's switch_rules /
    // example Makefiles. `-mtp=soft` matches what libnx is built
    // against; mismatching the TLS access mode crashes on the first
    // thread-local read.
    const arch = [_][]const u8{
        "-march=armv8-a+crc+crypto", "-mtune=cortex-a57", "-mtp=soft", "-fPIE",
    };

    const link = b.addSystemCommand(&.{gcc});
    link.addArgs(&arch);
    link.addArgs(&.{
        "-ffunction-sections", "-fdata-sections",
        "-D__SWITCH__",        "-O2",
        "-g",                  b.fmt("-specs={s}", .{libnx_specs}),
        // Pin the C standard to C11 (zig.h targets `_Noreturn`, not
        // C23's `[[noreturn]]`).
        "-std=gnu11",
        // zig's -ofmt=c emitter has known pointer/int-conversion
        // mismatches that gcc 14+ promotes to errors. We don't author
        // the C, so demote them.
                 "-Wno-incompatible-pointer-types",
        "-Wno-int-conversion", "-Wno-builtin-declaration-mismatch",
    });
    link.addArg(b.fmt("-I{s}", .{libnx_inc}));
    // zig's emitted C `#include "zig.h"`. The header lives in zig's
    // own lib directory; point gcc at it. aarch64 GCC's __int128
    // alignment matches zig's, so no patching is needed (unlike 3DS).
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

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const threeds_heap_mib = b.option(u32, "3ds-heap-mib", "3DS: regular libctru/newlib heap size in MiB (default: 4)");
    const threeds_linear_heap_mib = b.option(u32, "3ds-linear-heap-mib", "3DS: linear heap size in MiB (default: 60)");

    const overrides: Config.Overrides = .{
        .gfx = b.option(Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
        .audio = b.option(Audio, "audio", "Audio backend override (default: platform default)"),
        .psp_display_mode = b.option(PspDisplayMode, "psp-display", "PSP display mode: rgba8888 (32-bit, default) or rgb565 (16-bit)"),
        .psp_mipmaps = b.option(bool, "psp-mipmaps", "PSP: generate mip levels for VRAM-resident textures (default: false)"),
        .nintendo_3ds_heap_size = if (threeds_heap_mib) |mib| mib * 1024 * 1024 else null,
        .nintendo_3ds_linear_heap_size = if (threeds_linear_heap_mib) |mib| mib * 1024 * 1024 else null,
        .use_cwd = b.option(bool, "use-cwd", "Force resources+data dirs to CWD (debug/CI convenience; default: false)"),
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
        .smdh_long_description = "Aether engine test app",
        .smdh_author = "Aether",
        .resources = &.{
            .{ .path = b.path("test/test.png"), .name = "test.png" },
            .{ .path = b.path("test/calm1.wav"), .name = "calm1.wav" },
            .{ .path = b.path("test/grass1.wav"), .name = "grass1.wav" },
        },
        .romfs = if (config.platform == .nintendo_3ds) nintendo_romfs.getDirectory() else null,
        .switch_romfs = if (config.platform == .nintendo_switch) nintendo_romfs.getDirectory() else null,
    });

    const run_step = b.step("run", "Run the app");
    if (config.platform == .nintendo_3ds) {
        // 3DS can't run natively on the host. The 3DS-side homebrew
        // launcher listens for incoming .3dsx pushes on port 17491;
        // `3dslink` finds it via mDNS or accepts an explicit IP.
        const link_cmd = add3dslink(b, b.getInstallPath(.bin, "Aether-3DS/Aether.3dsx"));

        const link_step = b.step("3dslink", "Push the 3dsx to a networked 3DS via 3dslink");
        link_step.dependOn(&link_cmd.step);

        // `zig build run` aliases to 3dslink for 3DS so the same
        // command works across host/PSP/3DS workflows.
        run_step.dependOn(&link_cmd.step);
    } else if (config.platform == .nintendo_switch) {
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
        // command works across host/PSP/3DS/Switch workflows.
        run_step.dependOn(&link_cmd.step);
    } else {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    // Engine unit tests (desktop only — PSP/3DS/Switch pull in symbols
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
