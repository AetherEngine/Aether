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

pub const Config = struct {
    platform: Platform,
    gfx: Gfx,
    audio: Audio = Audio.default,
    input: Input = Input.default,
    psp_display_mode: PspDisplayMode = .rgba8888,

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
        };
    }

    pub const Overrides = struct {
        gfx: ?Gfx = null,
        psp_display_mode: ?PspDisplayMode = null,
    };
};

pub const GameOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode = .Debug,
    overrides: Config.Overrides = .{},
};

pub const ShaderPaths = struct {
    slang: std.Build.LazyPath,
};

/// Creates an executable with the Aether engine module and all platform
/// dependencies wired up. Returns the compile step so the caller can
/// further customize it (install, add run steps, etc.).
pub fn addGame(b: *std.Build, opts: GameOptions) *std.Build.Step.Compile {
    const config = Config.resolve(opts.target, opts.overrides);

    const options = b.addOptions();
    options.addOption(Config, "config", config);
    const options_module = options.createModule();

    const mod = b.addModule("Aether", .{
        .root_source_file = b.path("src/root.zig"),
        .target = opts.target,
        .imports = &.{
            .{ .name = "options", .module = options_module },
        },
    });

    // --- platform-specific engine dependencies ---
    if (config.platform == .psp) {
        const psp_dep = b.dependency("pspsdk", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });
        mod.addImport("pspsdk", psp_dep.module("pspsdk"));
    } else {
        const zglfw = b.dependency("zglfw", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });

        const glfw = b.dependency("glfw_zig", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });

        const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
            .api = .gl,
            .version = .@"4.5",
            .profile = .core,
            .extensions = &.{.ARB_gl_spirv},
        });

        const vulkan = b.dependency("vulkan", .{
            .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
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

    if (config.platform == .psp) {
        pspsdk.configurePspExecutable(exe);
    }

    if (config.platform == .windows and (opts.optimize == .ReleaseFast or opts.optimize == .ReleaseSmall)) {
        exe.subsystem = .windows;
    }

    return exe;
}

fn slangcPath(b: *std.Build) ?std.Build.LazyPath {
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
    const dep = b.lazyDependency(dep_name, .{}) orelse return null;
    return dep.path("bin/slangc");
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

/// Registers a shader pair for the game executable. Slang sources are
/// compiled to SPIR-V (Vulkan) or GLSL (OpenGL) via slangc. On
/// shaderless platforms (PSP), empty stubs are provided.
pub fn addShader(b: *std.Build, exe: *std.Build.Step.Compile, config: Config, comptime name: []const u8, paths: ShaderPaths) void {
    switch (config.gfx) {
        .vulkan => {
            const slangc = slangcPath(b);
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
            const slangc = slangcPath(b);
            const vert = addSlangStep(b, slangc, &.{
                "-target",  "glsl",       "-matrix-layout-column-major",
                "-profile", "glsl_460",   "-entry",               "vertexMain",
                "-stage",   "vertex",
            }, name ++ ".vert.glsl", paths.slang);
            const frag = addSlangStep(b, slangc, &.{
                "-target",  "glsl",         "-matrix-layout-column-major",
                "-profile", "glsl_460",     "-entry",               "fragmentMain",
                "-stage",   "fragment",
            }, name ++ ".frag.glsl", paths.slang);
            if (vert) |v| exe.root_module.addAnonymousImport(name ++ "_vert", .{ .root_source_file = v });
            if (frag) |f| exe.root_module.addAnonymousImport(name ++ "_frag", .{ .root_source_file = f });
        },
        .default => {
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
    };

    const config = Config.resolve(target, overrides);

    const exe = addGame(b, .{
        .name = "Aether",
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });

    addShader(b, exe, config, "basic", .{
        .slang = b.path("test/shaders/basic.slang"),
    });

    if (config.platform == .psp) {
        _ = pspsdk.addEbootSteps(b, exe, .{
            .title = "Aether",
            .output_dir = "Aether-PSP",
        });
    } else {
        b.installArtifact(exe);
    }

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
