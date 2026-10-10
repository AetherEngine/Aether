const std = @import("std");
const config_mod = @import("config.zig");
const shaders = @import("shaders.zig");
const tools = @import("tool_options.zig");
const zigglgen = @import("zigglgen");

const Config = config_mod.Config;

pub const GameOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize = .debug,
    overrides: Config.Overrides = .{},
};

pub const HeadlessOptions = struct {
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize = .debug,
    overrides: Config.Overrides = .{},
};

const user_root_import_name = "aether_user_root";

pub fn user_root_module(exe: *std.Build.Step.Compile) *std.Build.Module {
    return exe.root_module.import_table.get(user_root_import_name) orelse exe.root_module;
}

/// The engine module (`core/root.zig`) the application imports as "aether".
pub fn engine_module(exe: *std.Build.Step.Compile) *std.Build.Module {
    return user_root_module(exe).import_table.get("aether").?;
}

/// The independently configured Platform module backing this executable.
/// Use this module as the root of Platform tests to retain its SDK imports.
pub fn platform_module(exe: *std.Build.Step.Compile) *std.Build.Module {
    return engine_module(exe).import_table.get("platform").?;
}

/// Every target's executable root lives in platform/root/.
fn entry_root_source(config: Config) []const u8 {
    return switch (config.platform) {
        .linux, .macos, .windows => "platform/root/desktop.zig",
        .psp => "platform/root/psp.zig",
        .nintendo_3ds => "platform/root/3ds.zig",
        .nintendo_switch => "platform/root/switch.zig",
        .wasm => "platform/root/wasm.zig",
    };
}

const SwitchCImport = struct {
    import_name: []const u8,
    header: []const u8,
};

/// Platform-side libnx/deko3d headers.
const switch_platform_c_imports = [_]SwitchCImport{
    .{ .import_name = "switch_c", .header = "platform/switch/c.h" },
    .{ .import_name = "switch_deko_c", .header = "platform/switch/deko.h" },
};

fn add_nintendo_c_imports(owner: *std.Build, mod: *std.Build.Module, config: Config, dkp: []const u8, imports: []const SwitchCImport) void {
    const b = mod.owner;
    switch (config.platform) {
        .nintendo_switch => for (imports) |import| {
            const translate = b.addTranslateC(.{
                .root_source_file = owner.path(import.header),
                .target = mod.resolved_target.?,
                .optimize = mod.optimize.?,
            });
            // Newlib's fortified wrappers would otherwise emit references
            // to __ssp_real_* symbols.
            translate.defineCMacro("_FORTIFY_SOURCE", "0");
            translate.addIncludePath(b.graph.cwdRelativePath(b.pathJoin(&.{ dkp, "devkitA64/aarch64-none-elf/include" })));
            translate.addIncludePath(b.graph.cwdRelativePath(b.pathJoin(&.{ dkp, "libnx/include" })));
            mod.addImport(import.import_name, translate.createModule());
        },
        else => {},
    }
}

/// Creates an executable with the Aether engine module and all platform
/// dependencies wired up. Returns the compile step so the caller can further
/// customize it (install, add run steps, etc.).
pub fn add_game(owner: *std.Build, b: *std.Build, opts: GameOptions) *std.Build.Step.Compile {
    const config = Config.resolve(opts.target, opts.overrides);
    return add_executable(owner, b, opts.name, opts.root_source_file, opts.target, opts.optimize, config);
}

/// Creates an executable with the Aether engine module in headless mode
/// (no graphics, no windowing, no input). Useful for servers, tools, and
/// tests that only need engine logic (math, state machine, allocator).
pub fn add_headless(owner: *std.Build, b: *std.Build, opts: HeadlessOptions) *std.Build.Step.Compile {
    // Headless ignores any caller-supplied gfx/audio overrides -- those
    // devices are always stubbed in this mode. Other knobs (use_cwd,
    // PSP display/mip) flow through unchanged.
    var config = Config.resolve(opts.target, opts.overrides);
    config.gfx = .headless;
    config.audio = .none;
    return add_executable(owner, b, opts.name, opts.root_source_file, opts.target, opts.optimize, config);
}

fn add_executable(
    owner: *std.Build,
    b: *std.Build,
    name: []const u8,
    root_source_file: std.Build.LazyPath,
    requested_target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    config: Config,
) *std.Build.Step.Compile {
    const is_switch = config.platform == .nintendo_switch;
    const uses_zitrus = config.platform == .nintendo_3ds;
    const link_libc: ?bool = if (is_switch) true else null;

    // Switch forces ofmt=c -- there's no Zig-native backend for Horizon yet,
    // so we emit C and let devkitA64/libnx compile the result.
    const target = if (is_switch) blk: {
        var q = requested_target.query;
        q.ofmt = .c;
        break :blk b.resolveTargetQuery(q);
    } else requested_target;

    const options = b.addOptions();
    options.addOption(Config, "config", config);
    const options_module = options.createModule();

    // Each executable keeps its own Platform/options pair: native and web
    // builds can coexist in the same build graph without sharing backends.
    const platform_mod = b.createModule(.{
        .root_source_file = owner.path("platform/platform.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
        .imports = &.{
            .{ .name = "options", .module = options_module },
        },
    });
    const mod = b.createModule(.{
        .root_source_file = owner.path("core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "options", .module = options_module },
            .{ .name = "platform", .module = platform_mod },
        },
    });

    // --- Platform implementation dependencies ---
    const psp_dep = if (config.platform == .psp) owner.dependency("pspsdk", .{
        .target = target,
        .optimize = optimize,
    }) else null;
    const zitrus_dep = if (uses_zitrus) owner.dependency("zitrus", .{}) else null;

    switch (config.platform) {
        .psp => platform_mod.addImport("pspsdk", psp_dep.?.module("pspsdk")),
        .nintendo_3ds => platform_mod.addImport("zitrus", zitrus_dep.?.module("zitrus")),
        // Console SDK symbols come from translated libnx headers and are
        // resolved by the export pipeline's devkitPro link step.
        .nintendo_switch => add_nintendo_c_imports(owner, platform_mod, config, tools.devkit_pro_path(b), &switch_platform_c_imports),
        // Browser builds use host imports for WebGL/Web Audio/input and WASI
        // imports for files, clocks, stdio, random, and environment.
        .wasm => {},
        // A fully headless desktop build needs no windowing or audio library.
        .linux, .macos, .windows => if (config.gfx != .headless or config.audio != .none) {
            add_desktop_dependencies(owner, b, platform_mod, target, optimize);
        },
    }
    shaders.add_internal_shader_module(owner, b, platform_mod, config);

    // --- user executable ---
    const user_mod = b.createModule(.{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
        .strip = if (config.platform == .psp) false else null,
        .link_libc = link_libc,
        .imports = &.{
            .{ .name = "aether", .module = mod },
        },
    });

    const app_mod = b.createModule(.{
        .root_source_file = owner.path("platform/root/common.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
        .imports = &.{
            .{ .name = "aether", .module = mod },
            .{ .name = user_root_import_name, .module = user_mod },
        },
    });

    const root_mod = b.createModule(.{
        .root_source_file = owner.path(entry_root_source(config)),
        .target = target,
        .optimize = optimize,
        .link_libc = link_libc,
        .imports = &.{
            .{ .name = "platform", .module = platform_mod },
            .{ .name = "aether_app", .module = app_mod },
            // Lets `user_root_module` find the application's module.
            .{ .name = user_root_import_name, .module = user_mod },
        },
    });
    // Target SDKs read root declarations; applications may use them too.
    inline for (.{ "pspsdk", "zitrus" }) |sdk| {
        if (platform_mod.import_table.get(sdk)) |sdk_mod| {
            root_mod.addImport(sdk, sdk_mod);
            user_mod.addImport(sdk, sdk_mod);
        }
    }

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = root_mod,
        .zig_lib_dir = if (zitrus_dep) |zd| zd.namedLazyPath("juice/zig_lib") else null,
    });

    switch (config.platform) {
        .psp => {
            // Inline PSP config -- pspsdk.configurePspExecutable uses
            // dependencyFromBuildZig on exe.step.owner which fails when
            // the exe is owned by a downstream builder.
            exe.link_eh_frame_hdr = true;
            exe.link_emit_relocs = true;
            exe.entry = .{ .symbol_name = "module_start" };
            exe.setLinkerScript(psp_dep.?.path("tools/linkfile.ld"));
        },
        .nintendo_3ds => {
            exe.pie = true;
            exe.setLinkerScript(zitrus_dep.?.namedLazyPath("horizon/ld"));
        },
        // The Switch root exports C `main` itself. Keeping std/start's libc
        // main wrapper disabled avoids pulling in unsupported freestanding
        // libc/thread startup paths while still preserving the exported
        // root in the emitted C.
        .nintendo_switch => exe.entry = .disabled,
        .wasm => {
            exe.entry = .disabled;
            exe.rdynamic = true;
            exe.wasi_exec_model = .reactor;
            exe.shared_memory = true;
            exe.initial_memory = 64 * 1024 * 1024;
            exe.max_memory = 256 * 1024 * 1024;
        },
        .windows => if (config.gfx != .headless and (optimize == .fast or optimize == .small)) {
            exe.subsystem = .windows;
        },
        .linux, .macos => {},
    }

    return exe;
}

/// SDL3 windowing/input/audio, OpenGL bindings, and Vulkan for desktop targets.
fn add_desktop_dependencies(
    owner: *std.Build,
    b: *std.Build,
    platform_mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    const gl_bindings = zigglgen.generateBindingsModule(owner, .{
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
        .optimize = optimize,
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
        platform_mod.addLibraryPath(b.graph.cwdRelativePath(tools.macos_molten_vk_path(b)));
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
