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

        // macOS default is `.none` because the current miniaudio build is
        // bugged there. Flip back to `.default` with `-Daudio=default` once
        // that's fixed.
        const default_audio: Audio = switch (target.result.os.tag) {
            .macos => .none,
            else => .default,
        };

        return .{
            .platform = plat,
            .gfx = overrides.gfx orelse default_gfx,
            .audio = overrides.audio orelse default_audio,
            .psp_display_mode = overrides.psp_display_mode orelse .rgba8888,
            .psp_mipmaps = overrides.psp_mipmaps orelse false,
            .use_cwd = overrides.use_cwd orelse false,
        };
    }

    pub const Overrides = struct {
        gfx: ?Gfx = null,
        audio: ?Audio = null,
        psp_display_mode: ?PspDisplayMode = null,
        psp_mipmaps: ?bool = null,
        use_cwd: ?bool = null,
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

        if (config.audio != .none) {
            const zaudio_dep = owner.dependency("zaudio", .{
                .target = opts.target,
                .optimize = opts.optimize,
            });
            mod.addImport("zaudio", zaudio_dep.module("root"));
            mod.linkLibrary(zaudio_dep.artifact("miniaudio"));
        }

        if (opts.target.result.os.tag == .macos) {
            // Link MoltenVK directly as the Vulkan ICD — no loader. Feeds
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
        .audio = .none,
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
    /// build time via `sips` + `iconutil` (mac-only tools, which is fine —
    /// the .app branch only runs on mac builds). 1024×1024 PNG is ideal
    /// since every other size downscales cleanly from that; smaller
    /// sources are upscaled via bilinear, which is fine for placeholders.
    icon_png: ?std.Build.LazyPath = null,
    /// Files to install into the app bundle. On macOS they land under
    /// `Contents/Resources/<name>`. On desktop non-macOS they are copied
    /// alongside the exe in `zig-out/bin/`. Ignored on PSP.
    resources: []const Resource = &.{},

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
///   Contents/MacOS/<exe>                   — patched load commands
///   Contents/Frameworks/libMoltenVK.dylib  — id rewritten to @rpath
///   Contents/Frameworks/libglfw.3.dylib    — id rewritten to @rpath
///   Contents/Info.plist                    — minimum viable plist
///   Contents/Resources/<name>              — opts.resources
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
    // `codesign_allocate -r` — it removes LC_CODE_SIGNATURE and
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
            // best-effort — on failure the tmpdir leaks, but it's under /tmp.
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
    // then the exe, then the bundle dir — avoids --deep which is
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
        .audio = b.option(Audio, "audio", "Audio backend override (default: .none on macOS, .default elsewhere)"),
        .psp_display_mode = b.option(PspDisplayMode, "psp-display", "PSP display mode: rgba8888 (32-bit, default) or rgb565 (16-bit)"),
        .psp_mipmaps = b.option(bool, "psp-mipmaps", "PSP: generate mip levels for VRAM-resident textures (default: false)"),
        .use_cwd = b.option(bool, "use-cwd", "Force resources+data dirs to CWD (debug/CI convenience; default: false)"),
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
