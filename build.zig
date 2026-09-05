const std = @import("std");

pub const config = @import("build/config.zig");
pub const modules = @import("build/modules.zig");
pub const packaging = @import("build/packaging.zig");

// --- Aether's own build (test app + engine tests) ---

fn directory_exists(b: *std.Build, path: []const u8) bool {
    const io = b.graph.io;
    const full_path = b.pathFromRoot(path);
    var dir = std.Io.Dir.cwd().openDir(io, full_path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => {
            std.debug.panic("unable to open directory '{s}': {s}", .{ path, @errorName(err) });
        },
    };
    dir.close(io);

    return true;
}

fn make_resource_manifest(b: *std.Build, resource_dir_path: []const u8) []const u8 {
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

    const lint_dep = b.dependency("lint", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const run_lint = b.addRunArtifact(lint_dep.artifact("lint"));
    run_lint.setCwd(b.path("."));
    if (b.args) |args| run_lint.addArgs(args);
    run_lint.addArg(".");
    // Follow both module roots; named imports do not expose source paths.
    run_lint.addFileArg(b.path("core/root.zig"));
    run_lint.addFileArg(b.path("platform/platform.zig"));
    // This module is imported by its build-system name, aether_entry_common.
    run_lint.addFileArg(b.path("platform/entry_common.zig"));
    // Its only importer is the excluded C I/O wrapper; still check its implementation.
    run_lint.addFileArg(b.path("platform/switch/time.zig"));

    const lint_step = b.step("lint", "Lint the codebase with tiger_lint");
    lint_step.dependOn(&run_lint.step);

    const architecture_check = b.addExecutable(.{
        .name = "check-architecture",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_architecture.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run_architecture_check = b.addRunArtifact(architecture_check);
    run_architecture_check.addDirectoryArg(b.path("."));
    const architecture_tests = b.addTest(.{ .root_module = architecture_check.root_module });
    const run_architecture_tests = b.addRunArtifact(architecture_tests);
    const architecture_step = b.step("check-architecture", "Check Core/Platform source ownership and imports");
    architecture_step.dependOn(&run_architecture_check.step);
    architecture_step.dependOn(&run_architecture_tests.step);
    lint_step.dependOn(&run_architecture_check.step);

    const overrides: config.Config.Overrides = .{
        .gfx = b.option(config.Gfx, "gfx", "Graphics backend override (default: auto-detect from target)"),
        .audio = b.option(config.Audio, "audio", "Audio backend override (default: platform default)"),
        .psp_display_mode = b.option(config.PspDisplayMode, "psp-display", "PSP display mode: rgba8888 (32-bit, default) or rgb565 (16-bit)"),
        .psp_mipmaps = b.option(bool, "psp-mipmaps", "PSP: generate mip levels for VRAM-resident textures (default: false)"),
        .use_cwd = b.option(bool, "use-cwd", "Force resources+data dirs to CWD (debug/CI convenience; default: false)"),
        .flush_logs = b.option(bool, "flush-logs", "Flush aether.log after every log message (debugging hard hangs; default: false)"),
        .mesh_indexing = b.option(bool, "mesh-indexing", "Enable mesh index buffers (default: on except PSP/headless; override works on all backends)"),
        .nintendo_switch = b.option(bool, "nintendo-switch", "Build for Nintendo Switch (requires -Dtarget=aarch64-freestanding-none and devkitA64/libnx)"),
    };

    const resolved_config = config.Config.resolve(target, overrides);

    if (!directory_exists(b, "test")) {
        const missing_demo = b.addFail("Aether demo steps require the repository test/ directory.");
        b.step("run", "Run the app").dependOn(&missing_demo.step);
        b.step("web", "Build the browser-playable WASM site in zig-out/web").dependOn(&missing_demo.step);
        b.step("serve-web", "Serve zig-out/web with WASM MIME and COOP/COEP headers").dependOn(&missing_demo.step);
        b.step("test", "Run tests").dependOn(&missing_demo.step);
        return;
    }

    const exe = modules.add_game(b, b, .{
        .name = "Aether",
        .root_source_file = b.path("test/main.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });

    const api_smoke = modules.add_game(b, b, .{
        .name = "aether-api-smoke",
        .root_source_file = b.path("test/api_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .overrides = overrides,
    });
    b.step("check-api", "Compile public API probes for the selected target").dependOn(&api_smoke.step);
    if (resolved_config.platform == .linux or resolved_config.platform == .macos or resolved_config.platform == .windows) {
        const run_api_smoke = b.addRunArtifact(api_smoke);
        run_api_smoke.addArg("--exercise");
        b.step("test-api", "Run CPU geometry and thread lifetime probes").dependOn(&run_api_smoke.step);
    }

    const nintendo_romfs = b.addWriteFiles();
    _ = nintendo_romfs.addCopyFile(b.path("test/test.png"), "test.png");
    _ = nintendo_romfs.addCopyFile(b.path("test/calm1.wav"), "calm1.wav");
    _ = nintendo_romfs.addCopyFile(b.path("test/grass1.wav"), "grass1.wav");

    const package = packaging.export_artifact_with_outputs(b, b, exe, resolved_config, .{
        .title = "Aether",
        .output_dir = switch (resolved_config.platform) {
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
        .nintendo_3ds_romfs = if (resolved_config.platform == .nintendo_3ds) nintendo_romfs.getDirectory() else null,
        .switch_romfs = if (resolved_config.platform == .nintendo_switch) nintendo_romfs.getDirectory() else null,
    });

    const web_target = config.web_target(b);
    const web_overrides: config.Config.Overrides = .{
        .gfx = .webgl,
        .use_cwd = true,
    };
    const web_exe = modules.add_game(b, b, .{
        .name = "Aether",
        .root_source_file = b.path("test/web_main.zig"),
        .target = web_target,
        .optimize = optimize,
        .overrides = web_overrides,
    });
    const web_install = packaging.add_web_bundle(b, b, web_exe, .{
        .web_resources = b.path(web_resources_path),
        .web_resource_manifest = make_resource_manifest(b, web_resources_path),
    });

    const web_step = b.step("web", "Build the browser-playable WASM site in zig-out/web");
    web_step.dependOn(&web_install.step);

    const serve_web_cmd = packaging.add_serve_web_step(b, b, "aether-serve-web", web_install, web_host, web_port);

    const serve_web_step = b.step("serve-web", "Serve zig-out/web with WASM MIME and COOP/COEP headers");
    serve_web_step.dependOn(&serve_web_cmd.step);

    const run_step = b.step("run", "Run the app");
    if (resolved_config.platform == .nintendo_switch) {
        // Switch can't run natively on the host. nxlink pushes the .nro to
        // nx-hbloader on a networked Switch.
        const dkp = @import("build/tool_options.zig").devkit_pro_path(b);
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
            link_cmd.addArg("--args");
            link_cmd.addArgs(args);
        }

        const link_step = b.step("nxlink", "Push the nro to a networked Switch via nxlink");
        link_step.dependOn(&link_cmd.step);

        run_step.dependOn(&link_cmd.step);
    } else if (resolved_config.platform == .nintendo_3ds) {
        // Zitrus owns the 3dslink-protocol client, so running a 3DS target
        // does not need devkitPro's external 3dslink executable.
        const threedsx = package.nintendo_3dsx orelse unreachable;
        const link_cmd = packaging.add_link3dsx(b, threedsx, .{
            .address = b.option([]const u8, "3dslink-address", "3DS: target IP/hostname for Zitrus link (default: broadcast discovery)"),
            .retries = b.option(u32, "3dslink-retries", "3DS: Zitrus link broadcast retry count"),
        });
        link_cmd.step.dependOn(b.getInstallStep());

        const link_step = b.step("3dslink", "Send the 3dsx to a networked 3DS via Zitrus");
        link_step.dependOn(&link_cmd.step);

        run_step.dependOn(&link_cmd.step);
    } else {
        const run_cmd = b.addRunArtifact(exe);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| run_cmd.addArgs(args);
        run_step.dependOn(&run_cmd.step);
    }

    // Engine unit tests (desktop only -- PSP/3DS/Switch pull in symbols that
    // can't be linked or analyzed under the test runner).
    if (resolved_config.platform != .psp and resolved_config.platform != .nintendo_3ds and resolved_config.platform != .nintendo_switch) {
        const mod_tests = b.addTest(.{
            .root_module = exe.root_module.import_table.get("aether").?,
            .use_llvm = exe.use_llvm,
            .use_lld = exe.use_lld,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);
        const platform_tests = b.addTest(.{
            .root_module = modules.platform_module(exe),
            .use_llvm = exe.use_llvm,
            .use_lld = exe.use_lld,
        });
        const run_platform_tests = b.addRunArtifact(platform_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
        test_step.dependOn(&run_platform_tests.step);
        test_step.dependOn(&run_architecture_check.step);
        test_step.dependOn(&run_architecture_tests.step);
    }
}
