const std = @import("std");
const config_mod = @import("config.zig");
const shaders = @import("shaders.zig");
const tools = @import("tool_options.zig");

const Config = config_mod.Config;

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

const user_root_import_name = "aether_user_root";

pub fn userRootModule(exe: *std.Build.Step.Compile) *std.Build.Module {
    return exe.root_module.import_table.get(user_root_import_name) orelse exe.root_module;
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
/// dependencies wired up. Returns the compile step so the caller can further
/// customize it (install, add run steps, etc.).
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
            // Link MoltenVK directly as the Vulkan ICD -- no loader.
            mod.addLibraryPath(.{ .cwd_relative = tools.macosMoltenVkPath(b) });
            mod.addLibraryPath(.{ .cwd_relative = tools.macosGlfwPath(b) });
            mod.linkSystemLibrary("MoltenVK", .{});
            mod.linkSystemLibrary("glfw3", .{});

            // rpath for the .app bundle layout.
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
        addNintendoCImportPaths(owner, mod, config, tools.devkitProPath(b));
    }
    shaders.addInternalShaderModule(owner, b, mod, config);

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
        addNintendoCImportPaths(owner, root_mod, config, tools.devkitProPath(b));
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
        addNintendoCImportPaths(owner, mod, config, tools.devkitProPath(b));
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
        addNintendoCImportPaths(owner, root_mod, config, tools.devkitProPath(b));
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
