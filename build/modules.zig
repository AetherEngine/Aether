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

pub fn user_root_module(exe: *std.Build.Step.Compile) *std.Build.Module {
    return exe.root_module.import_table.get(user_root_import_name) orelse exe.root_module;
}

/// The independently configured Platform module backing this executable.
/// Use this module as the root of Platform tests to retain its SDK imports.
pub fn platform_module(exe: *std.Build.Step.Compile) *std.Build.Module {
    const core_mod = user_root_module(exe).import_table.get("aether").?;
    return core_mod.import_table.get("platform").?;
}

fn entry_root_source(config: Config) []const u8 {
    return switch (config.platform) {
        .psp => "platform/psp/entry.zig",
        .nintendo_3ds => "platform/3ds/entry.zig",
        .nintendo_switch => "platform/switch/services.zig",
        .wasm => unreachable,
        else => "platform/entry.zig",
    };
}

fn add_nintendo_c_import_paths(_: *std.Build, mod: *std.Build.Module, config: Config, dkp: []const u8) void {
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
pub fn add_game(owner: *std.Build, b: *std.Build, opts: GameOptions) *std.Build.Step.Compile {
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

    // Each executable keeps its own Platform/options pair: native and web
    // builds can coexist in the same build graph without sharing backends.
    const platform_mod = b.createModule(.{
        .root_source_file = owner.path("platform/platform.zig"),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "options", .module = options_module },
        },
    });
    const mod = b.addModule("Aether", .{
        .root_source_file = owner.path("core/root.zig"),
        .target = target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "options", .module = options_module },
            .{ .name = "platform", .module = platform_mod },
        },
    });

    // --- Platform implementation dependencies ---
    const psp_dep = if (config.platform == .psp) owner.dependency("pspsdk", .{
        .target = target,
        .optimize = opts.optimize,
    }) else null;
    const zitrus_dep = if (uses_zitrus) owner.dependency("zitrus", .{}) else null;

    if (psp_dep) |pd| {
        platform_mod.addImport("pspsdk", pd.module("pspsdk"));
    } else if (zitrus_dep) |zd| {
        platform_mod.addImport("zitrus", zd.module("zitrus"));
    } else if (config.platform == .nintendo_switch) {
        // Console SDK symbols are declared as backend-local externs and
        // resolved by the export pipeline's devkitPro link step.
    } else if (config.platform == .wasm) {
        // Browser builds use host imports for WebGL/Web Audio/input and WASI
        // imports for files, clocks, stdio, random, and environment. They do
        // not link desktop windowing/audio dependencies.
    } else {
        const gl_bindings = @import("zigglgen").generateBindingsModule(owner, .{
            .api = .gl,
            .version = .@"4.5",
            .profile = .core,
        });

        const vulkan = owner.dependency("vulkan", .{
            .registry = owner.dependency("vulkan_headers", .{}).path("registry/vk.xml"),
        }).module("vulkan-zig");

        // SDL3 provides desktop windowing, input, and audio, and is linked
        // statically on every desktop target.
        if (owner.lazyDependency("sdl3", .{
            .target = target,
            .optimize = opts.optimize,
            .main = false,
            .ext_image = false,
            .ext_net = false,
            .ext_ttf = false,
            .c_sdl_preferred_linkage = .static,
        })) |sdl3_dep| {
            platform_mod.addImport("sdl3", sdl3_dep.module("sdl3"));
        }

        platform_mod.addImport("gl", gl_bindings);
        platform_mod.addImport("vulkan", vulkan);

        if (target.result.os.tag == .macos) {
            // The statically-linked SDL3 archive's Apple framework
            // dependencies don't propagate through module imports, so link
            // them here. Mirrors the list in the SDL package's build script,
            // but links the concrete frameworks (AppKit, CoreFoundation,
            // CoreGraphics, CoreServices) directly: the umbrella tbds in the
            // zig system_sdk don't re-export their subframeworks.
            platform_mod.linkFramework("CoreMedia", .{});
            platform_mod.linkFramework("CoreVideo", .{});
            platform_mod.linkFramework("Cocoa", .{});
            platform_mod.linkFramework("AppKit", .{});
            platform_mod.linkFramework("CoreFoundation", .{});
            platform_mod.linkFramework("CoreGraphics", .{});
            platform_mod.linkFramework("CoreServices", .{});
            platform_mod.linkFramework("CoreVideo", .{});
            platform_mod.linkFramework("Cocoa", .{});
            platform_mod.linkFramework("UniformTypeIdentifiers", .{ .weak = true });
            platform_mod.linkFramework("IOKit", .{});
            platform_mod.linkFramework("ForceFeedback", .{});
            platform_mod.linkFramework("Carbon", .{});
            platform_mod.linkFramework("CoreAudio", .{});
            platform_mod.linkFramework("AudioToolbox", .{});
            platform_mod.linkFramework("AVFoundation", .{});
            platform_mod.linkFramework("Foundation", .{});
            platform_mod.linkFramework("GameController", .{});
            platform_mod.linkFramework("Metal", .{});
            platform_mod.linkFramework("QuartzCore", .{});
            platform_mod.linkFramework("CoreHaptics", .{ .weak = true });
            // Objective-C runtime for SDL's Cocoa .m objects.
            platform_mod.linkSystemLibrary("objc", .{});

            // Link MoltenVK directly as the Vulkan ICD -- no loader.
            platform_mod.addLibraryPath(.{ .cwd_relative = tools.macos_molten_vk_path(b) });
            platform_mod.linkSystemLibrary("MoltenVK", .{});

            // rpath for the .app bundle layout.
            platform_mod.addRPathSpecial("@executable_path/../Frameworks");

            if (owner.lazyDependency("system_sdk", .{})) |system_sdk| {
                platform_mod.addFrameworkPath(system_sdk.path("macos12/System/Library/Frameworks"));
                platform_mod.addSystemIncludePath(system_sdk.path("macos12/usr/include"));
                platform_mod.addLibraryPath(system_sdk.path("macos12/usr/lib"));
            }
        }
    }

    if (uses_nintendo_c_io) {
        add_nintendo_c_import_paths(owner, platform_mod, config, tools.devkit_pro_path(b));
    }
    shaders.add_internal_shader_module(owner, b, platform_mod, config);

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
    if (zitrus_dep) |_| {
        user_mod.addImport("zitrus", platform_mod.import_table.get("zitrus").?);
    }

    const entry_common_mod = if (config.platform != .wasm) b.createModule(.{
        .root_source_file = owner.path("platform/entry_common.zig"),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
        },
    }) else null;

    const root_mod = if (config.platform != .wasm) b.createModule(.{
        .root_source_file = owner.path(entry_root_source(config)),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
            .{ .name = "options", .module = options_module },
            .{ .name = "aether_entry_common", .module = entry_common_mod.? },
        },
    }) else user_mod;
    if (psp_dep) |_| {
        root_mod.addImport("pspsdk", platform_mod.import_table.get("pspsdk").?);
    }
    if (zitrus_dep) |_| {
        root_mod.addImport("zitrus", platform_mod.import_table.get("zitrus").?);
    }
    if (uses_nintendo_c_io) {
        // The Switch executable shim also imports native console headers.
        add_nintendo_c_import_paths(owner, root_mod, config, tools.devkit_pro_path(b));
    }

    // Zig 0.16's self-hosted linker cannot handle .sframe in newer glibc CRT objects.
    const linux_glibc = target.result.os.tag == .linux and target.result.abi.isGnu();
    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = root_mod,
        .zig_lib_dir = if (zitrus_dep) |zd| zd.namedLazyPath("juice/zig_lib") else null,
        .use_llvm = if (linux_glibc) true else null,
        .use_lld = if (linux_glibc) true else null,
    });

    if (psp_dep) |pd| {
        // Inline PSP config -- pspsdk.configurePspExecutable uses
        // dependencyFromBuildZig on exe.step.owner which fails when
        // the exe is owned by a downstream builder.
        if (user_root_module(exe).import_table.get("pspsdk") == null) {
            user_root_module(exe).addImport("pspsdk", platform_mod.import_table.get("pspsdk").?);
        }
        exe.link_eh_frame_hdr = true;
        exe.link_emit_relocs = true;
        exe.entry = .{ .symbol_name = "module_start" };
        exe.setLinkerScript(pd.path("tools/linkfile.ld"));
    }

    if (zitrus_dep) |zd| {
        if (user_root_module(exe).import_table.get("zitrus") == null) {
            user_root_module(exe).addImport("zitrus", platform_mod.import_table.get("zitrus").?);
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
pub fn add_headless(owner: *std.Build, b: *std.Build, opts: HeadlessOptions) *std.Build.Step.Compile {
    // Headless ignores any caller-supplied gfx/audio overrides -- those
    // backends are always stubbed in this mode. Other knobs (use_cwd,
    // PSP display/mip) flow through unchanged.
    var config = Config.resolve(opts.target, opts.overrides);
    config.gfx = .headless;
    config.audio = .none;
    const uses_nintendo_c_io = config.platform == .nintendo_switch;
    const uses_zitrus = config.platform == .nintendo_3ds;

    // Switch forces ofmt=c (see add_game for details).
    const target = if (uses_nintendo_c_io) blk: {
        var q = opts.target.query;
        q.ofmt = .c;
        break :blk b.resolveTargetQuery(q);
    } else opts.target;

    const options = b.addOptions();
    options.addOption(Config, "config", config);
    const options_module = options.createModule();

    const platform_mod = b.createModule(.{
        .root_source_file = owner.path("platform/platform.zig"),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "options", .module = options_module },
        },
    });
    const mod = b.addModule("Aether", .{
        .root_source_file = owner.path("core/root.zig"),
        .target = target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "options", .module = options_module },
            .{ .name = "platform", .module = platform_mod },
        },
    });

    const psp_dep = if (config.platform == .psp) owner.dependency("pspsdk", .{
        .target = target,
        .optimize = opts.optimize,
    }) else null;
    const zitrus_dep = if (uses_zitrus) owner.dependency("zitrus", .{}) else null;

    if (psp_dep) |pd| {
        platform_mod.addImport("pspsdk", pd.module("pspsdk"));
    } else if (zitrus_dep) |zd| {
        platform_mod.addImport("zitrus", zd.module("zitrus"));
    }

    if (uses_nintendo_c_io) {
        add_nintendo_c_import_paths(owner, platform_mod, config, tools.devkit_pro_path(b));
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
    if (zitrus_dep) |_| {
        user_mod.addImport("zitrus", platform_mod.import_table.get("zitrus").?);
    }

    const entry_common_mod = if (config.platform != .wasm) b.createModule(.{
        .root_source_file = owner.path("platform/entry_common.zig"),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
        },
    }) else null;

    const root_mod = if (config.platform != .wasm) b.createModule(.{
        .root_source_file = owner.path(entry_root_source(config)),
        .target = target,
        .optimize = opts.optimize,
        .link_libc = if (uses_nintendo_c_io) true else null,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
            .{ .name = "options", .module = options_module },
            .{ .name = "aether_entry_common", .module = entry_common_mod.? },
        },
    }) else user_mod;
    if (psp_dep) |_| {
        root_mod.addImport("pspsdk", platform_mod.import_table.get("pspsdk").?);
    }
    if (zitrus_dep) |_| {
        root_mod.addImport("zitrus", platform_mod.import_table.get("zitrus").?);
    }
    if (uses_nintendo_c_io) {
        // The Switch executable shim also imports native console headers.
        add_nintendo_c_import_paths(owner, root_mod, config, tools.devkit_pro_path(b));
    }

    // Keep headless executables on the same Linux glibc linker path as games.
    const linux_glibc = target.result.os.tag == .linux and target.result.abi.isGnu();
    const exe = b.addExecutable(.{
        .name = opts.name,
        .root_module = root_mod,
        .zig_lib_dir = if (zitrus_dep) |zd| zd.namedLazyPath("juice/zig_lib") else null,
        .use_llvm = if (linux_glibc) true else null,
        .use_lld = if (linux_glibc) true else null,
    });

    if (psp_dep) |pd| {
        if (user_root_module(exe).import_table.get("pspsdk") == null) {
            user_root_module(exe).addImport("pspsdk", platform_mod.import_table.get("pspsdk").?);
        }
        exe.link_eh_frame_hdr = true;
        exe.link_emit_relocs = true;
        exe.entry = .{ .symbol_name = "module_start" };
        exe.setLinkerScript(pd.path("tools/linkfile.ld"));
    }

    if (zitrus_dep) |zd| {
        if (user_root_module(exe).import_table.get("zitrus") == null) {
            user_root_module(exe).addImport("zitrus", platform_mod.import_table.get("zitrus").?);
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
