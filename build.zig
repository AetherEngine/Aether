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

pub const Config = struct {
    platform: Platform,
    gfx: Gfx,
    audio: Audio = Audio.default,
    input: Input = Input.default,

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
        };
    }

    pub const Overrides = struct {
        gfx: ?Gfx = null,
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
    glsl_vert: std.Build.LazyPath,
    glsl_frag: std.Build.LazyPath,
    vulkan_vert: std.Build.LazyPath,
    vulkan_frag: std.Build.LazyPath,
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
        // PSP: no GLFW/GL/Vulkan
    } else {
        const zglfw = b.dependency("zglfw", .{
            .target = opts.target,
            .optimize = opts.optimize,
        });

        const gl_bindings = @import("zigglgen").generateBindingsModule(b, .{
            .api = .gl,
            .version = .@"4.5",
            .profile = .core,
            .extensions = &.{},
        });

        const vulkan = b.dependency("vulkan", .{
            .registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
        }).module("vulkan-zig");

        mod.addImport("glfw", zglfw.module("glfw"));
        mod.addImport("gl", gl_bindings);
        mod.addImport("vulkan", vulkan);
        mod.linkSystemLibrary("glfw3", .{});

        if (opts.target.result.os.tag == .macos) {
            mod.linkSystemLibrary("vulkan", .{});
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

    return exe;
}

/// Registers a shader pair for the game executable. On Vulkan targets,
/// the Vulkan GLSL sources are compiled to SPIR-V via glslc. On OpenGL
/// targets, the GLSL sources are embedded directly. On shaderless
/// platforms, this is a no-op.
pub fn addShader(b: *std.Build, exe: *std.Build.Step.Compile, config: Config, comptime name: []const u8, paths: ShaderPaths) void {
    switch (config.gfx) {
        .vulkan => {
            const vert_cmd = b.addSystemCommand(&.{
                "glslc",
                "--target-env=vulkan1.3",
                "-o",
            });
            const vert_spv = vert_cmd.addOutputFileArg(name ++ ".vert.spv");
            vert_cmd.addFileArg(paths.vulkan_vert);
            exe.root_module.addAnonymousImport(name ++ "_vert", .{
                .root_source_file = vert_spv,
            });

            const frag_cmd = b.addSystemCommand(&.{
                "glslc",
                "--target-env=vulkan1.3",
                "-o",
            });
            const frag_spv = frag_cmd.addOutputFileArg(name ++ ".frag.spv");
            frag_cmd.addFileArg(paths.vulkan_frag);
            exe.root_module.addAnonymousImport(name ++ "_frag", .{
                .root_source_file = frag_spv,
            });
        },
        .opengl => {
            exe.root_module.addAnonymousImport(name ++ "_vert", .{
                .root_source_file = paths.glsl_vert,
            });
            exe.root_module.addAnonymousImport(name ++ "_frag", .{
                .root_source_file = paths.glsl_frag,
            });
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
        .glsl_vert = b.path("test/shaders/basic.vert"),
        .glsl_frag = b.path("test/shaders/basic.frag"),
        .vulkan_vert = b.path("test/shaders/basic_vk.vert"),
        .vulkan_frag = b.path("test/shaders/basic_vk.frag"),
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
