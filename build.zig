const std = @import("std");
const pspsdk = @import("pspsdk");

pub const Platform = enum {
    windows,
    linux,
    macos,
    psp,
};

pub const Gfx = enum {
    default,
    opengl,
    vulkan,
    headless,
};

pub const Audio = enum(u8) {
    default,
};

pub const Input = enum(u8) {
    default,
};

pub const PspDisplayMode = enum {
    rgba8888,
    rgb565,
};

pub const PspBackend = enum {
    /// New default: drives the GE directly through the pspsdk ge_list
    /// CommandBuffer API for explicit display-list ownership.
    ge_list,
    /// Legacy backend that goes through pspsdk's gu wrapper.
    gu,
};

pub const Config = struct {
    platform: Platform,
    gfx: Gfx,
    audio: Audio = Audio.default,
    input: Input = Input.default,
    psp_display_mode: PspDisplayMode = .rgba8888,
    psp_backend: PspBackend = .ge_list,

    pub fn resolve(target: std.Build.ResolvedTarget, overrides: Overrides) Config {
        const plat: Platform = switch (target.result.os.tag) {
            .windows => .windows,
            .macos => .macos,
            .linux => .linux,
            .psp => .psp,
            else => |t| {
                std.debug.panic("Unsupported OS! {}\n", .{t});
            },
        };

        const default_gfx: Gfx = switch (target.result.os.tag) {
            .windows => .vulkan,
            .macos => .vulkan,
            .linux => .vulkan,
            else => .default,
        };

        return .{
            .platform = plat,
            .gfx = overrides.gfx orelse default_gfx,
            .psp_display_mode = overrides.psp_display_mode orelse .rgba8888,
            .psp_backend = overrides.psp_backend orelse .ge_list,
        };
    }

    pub const Overrides = struct {
        gfx: ?Gfx = null,
        psp_display_mode: ?PspDisplayMode = null,
        psp_backend: ?PspBackend = null,
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
};

pub const ShaderPaths = struct {
    slang: std.Build.LazyPath,
};

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

    const options = b.addOptions();
    options.addOption(Config, "config", config);
    const options_module = options.createModule();

    const mod = b.addModule("Aether", .{
        .root_source_file = owner.path("src/root.zig"),
        .target = opts.target,
        .imports = &.{
            .{ .name = "options", .module = options_module },
        },
    });

    // --- platform-specific engine dependencies ---
    const psp_dep = if (config.platform == .psp) owner.dependency("pspsdk", .{
        .target = opts.target,
        .optimize = opts.optimize,
    }) else null;

    if (psp_dep) |pd| {
        mod.addImport("pspsdk", pd.module("pspsdk"));
    } else {
        const zglfw = owner.dependency("zglfw", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });

        const glfw = owner.dependency("glfw_zig", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });

        const gl_bindings = @import("zigglgen").generateBindingsModule(owner, .{
            .api = .gl,
            .version = .@"4.5",
            .profile = .core,
            .extensions = &.{.ARB_gl_spirv},
        });

        const vulkan = owner.dependency("vulkan", .{
            .registry = owner.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
        }).module("vulkan-zig");

        mod.addImport("glfw", zglfw.module("glfw"));
        mod.addImport("gl", gl_bindings);
        mod.addImport("vulkan", vulkan);

        if (opts.target.result.os.tag == .macos) {
            mod.linkSystemLibrary("vulkan", .{});
            mod.linkSystemLibrary("glfw3", .{});
        } else {
            mod.linkLibrary(glfw.artifact("glfw"));
        }
    }

    // --- user executable ---
    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = b.createModule(.{
            .root_source_file = opts.root_source_file,
            .target = opts.target,
            .optimize = opts.optimize,
            .strip = if (config.platform == .psp) false else null,
            .imports = &.{
                .{ .name = "aether", .module = mod },
            },
        }),
    });

    if (psp_dep) |pd| {
        // Inline PSP config — pspsdk.configurePspExecutable uses
        // dependencyFromBuildZig on exe.step.owner which fails when
        // the exe is owned by a downstream builder.
        if (exe.root_module.import_table.get("pspsdk") == null) {
            exe.root_module.addImport("pspsdk", mod.import_table.get("pspsdk").?);
        }
        exe.link_eh_frame_hdr = true;
        exe.link_emit_relocs = true;
        exe.entry = .{ .symbol_name = "module_start" };
        exe.setLinkerScript(pd.path("tools/linkfile.ld"));
    }

    if (config.platform == .windows and (opts.optimize == .ReleaseFast or opts.optimize == .ReleaseSmall)) {
        exe.subsystem = .windows;
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
    const config = Config{
        .platform = Config.resolve(opts.target, .{}).platform,
        .gfx = .headless,
    };

    const options = b.addOptions();
    options.addOption(Config, "config", config);
    const options_module = options.createModule();

    const mod = b.addModule("Aether", .{
        .root_source_file = owner.path("src/root.zig"),
        .target = opts.target,
        .imports = &.{
            .{ .name = "options", .module = options_module },
        },
    });

    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = b.createModule(.{
            .root_source_file = opts.root_source_file,
            .target = opts.target,
            .optimize = opts.optimize,
            .imports = &.{
                .{ .name = "aether", .module = mod },
            },
        }),
    });

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

fn addSlangStep(b: *std.Build, slangc: ?std.Build.LazyPath, args: []const []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) ?std.Build.LazyPath {
    const sc = slangc orelse return null;
    const run = std.Build.Step.Run.create(b, "slangc " ++ output_name);
    run.addFileArg(sc);
    run.addArgs(args);
    run.addArg("-o");
    const output = run.addOutputFileArg(output_name);
    run.addFileArg(input);
    return output;
}

pub const ExportOptions = struct {
    /// PSP: title shown on the XMB. Ignored on other platforms.
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
};

/// Installs the game executable with platform-appropriate packaging.
/// On desktop this calls `b.installArtifact`. On PSP this runs the
/// ELF -> PRX -> SFO -> EBOOT.PBP pipeline via pspsdk.
pub fn exportArtifact(owner: *std.Build, b: *std.Build, exe: *std.Build.Step.Compile, config: Config, opts: ExportOptions) void {
    if (config.platform == .psp) {
        // Resolve pspsdk artifacts from `owner` (which has pspsdk in
        // its dep tree), but run the pipeline on `b` so install steps
        // register on the downstream project's builder.
        const psp_dep = owner.dependency("pspsdk", .{});
        _ = pspEbootPipeline(b, exe, psp_dep, opts);
    } else {
        b.installArtifact(exe);
    }
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

/// Registers a shader pair for the game executable. Slang sources are
/// compiled to SPIR-V (Vulkan) or GLSL (OpenGL) via slangc. On
/// shaderless platforms (PSP), empty stubs are provided.
///
/// When called from Aether's own build, use `addShader(b, b, ...)`.
/// From a downstream project:
///
///     Aether.addShader(ae_dep.builder, b, exe, config, "basic", .{ ... });
///
pub fn addShader(owner: *std.Build, b: *std.Build, exe: *std.Build.Step.Compile, config: Config, comptime name: []const u8, paths: ShaderPaths) void {
    switch (config.gfx) {
        .vulkan => {
            const slangc = slangcPath(owner);
            const vert = addSlangStep(b, slangc, &.{
                "-target",  "spirv",  "-emit-spirv-directly", "-matrix-layout-column-major",
                "-DVULKAN", "-entry", "vertexMain",           "-stage",
                "vertex",
            }, name ++ ".vert.spv", paths.slang);
            const frag = addSlangStep(b, slangc, &.{
                "-target",  "spirv",  "-emit-spirv-directly", "-matrix-layout-column-major",
                "-DVULKAN", "-entry", "fragmentMain",         "-stage",
                "fragment",
            }, name ++ ".frag.spv", paths.slang);
            if (vert) |v| exe.root_module.addAnonymousImport(name ++ "_vert", .{ .root_source_file = v });
            if (frag) |f| exe.root_module.addAnonymousImport(name ++ "_frag", .{ .root_source_file = f });
        },
        .opengl => {
            const slangc = slangcPath(owner);
            const vert = addSlangStep(b, slangc, &.{
                "-target",    "glsl",     "-matrix-layout-column-major",
                "-profile",   "glsl_460", "-entry",
                "vertexMain", "-stage",   "vertex",
            }, name ++ ".vert.glsl", paths.slang);
            const frag = addSlangStep(b, slangc, &.{
                "-target",      "glsl",     "-matrix-layout-column-major",
                "-profile",     "glsl_460", "-entry",
                "fragmentMain", "-stage",   "fragment",
            }, name ++ ".frag.glsl", paths.slang);
            if (vert) |v| exe.root_module.addAnonymousImport(name ++ "_vert", .{ .root_source_file = v });
            if (frag) |f| exe.root_module.addAnonymousImport(name ++ "_frag", .{ .root_source_file = f });
        },
        .default, .headless => {
            // Provide empty stubs so @embedFile(name ++ "_vert") still compiles.
            const empty = b.addWriteFiles();
            const stub = empty.add(name ++ "_stub", "");
            exe.root_module.addAnonymousImport(name ++ "_vert", .{
                .root_source_file = stub,
            });
            exe.root_module.addAnonymousImport(name ++ "_frag", .{
                .root_source_file = stub,
            });
        },
    }
}

// --- Aether's own build (test app + engine tests) ---

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const overrides: Config.Overrides = .{
        .gfx = b.option(Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
        .psp_display_mode = b.option(PspDisplayMode, "psp-display", "PSP display mode: rgba8888 (32-bit, default) or rgb565 (16-bit)"),
        .psp_backend = b.option(PspBackend, "psp-backend", "PSP graphics backend: ge_list (default) or gu (legacy)"),
    };

    const config = Config.resolve(target, overrides);

    const exe = addGame(b, b, .{
        .name = "Aether",
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });

    addShader(b, b, exe, config, "basic", .{
        .slang = b.path("test/shaders/basic.slang"),
    });

    exportArtifact(b, b, exe, config, .{
        .title = "Aether",
        .output_dir = "Aether-PSP",
    });

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Engine unit tests (desktop only)
    if (config.platform != .psp) {
        const mod_tests = b.addTest(.{
            .root_module = exe.root_module.import_table.get("aether").?,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
    }
}
