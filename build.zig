const std = @import("std");

pub const config = @import("build/config.zig");
pub const modules = @import("build/modules.zig");
pub const packaging = @import("build/packaging.zig");

// --- Aether's own build (test app + engine tests) ---

fn directoryExists(b: *std.Build, path: []const u8) bool {
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

    if (!directoryExists(b, "test")) {
        const missing_demo = b.addFail("Aether demo steps require the repository test/ directory.");
        b.step("run", "Run the app").dependOn(&missing_demo.step);
        b.step("web", "Build the browser-playable WASM site in zig-out/web").dependOn(&missing_demo.step);
        b.step("serve-web", "Serve zig-out/web with WASM MIME and COOP/COEP headers").dependOn(&missing_demo.step);
        b.step("test", "Run tests").dependOn(&missing_demo.step);
        return;
    }

    const exe = modules.addGame(b, b, .{
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

    packaging.exportArtifact(b, b, exe, resolved_config, .{
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

    const web_target = config.webTarget(b);
    const web_overrides: config.Config.Overrides = .{
        .gfx = .webgl,
        .use_cwd = true,
    };
    const web_exe = modules.addGame(b, b, .{
        .name = "Aether",
        .root_source_file = b.path("test/web_main.zig"),
        .target = web_target,
        .optimize = optimize,
        .overrides = web_overrides,
    });
    const web_install = packaging.addWebBundle(b, b, web_exe, .{
        .web_resources = b.path(web_resources_path),
        .web_resource_manifest = makeResourceManifest(b, web_resources_path),
    });

    const web_step = b.step("web", "Build the browser-playable WASM site in zig-out/web");
    web_step.dependOn(&web_install.step);

    const serve_web_cmd = packaging.addServeWebStep(b, b, "aether-serve-web", web_install, web_host, web_port);

    const serve_web_step = b.step("serve-web", "Serve zig-out/web with WASM MIME and COOP/COEP headers");
    serve_web_step.dependOn(&serve_web_cmd.step);

    const run_step = b.step("run", "Run the app");
    if (resolved_config.platform == .nintendo_switch) {
        // Switch can't run natively on the host. nxlink pushes the .nro to
        // nx-hbloader on a networked Switch.
        const dkp = @import("build/tool_options.zig").devkitProPath(b);
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
        const link_cmd = packaging.add3dslink(b, b.getInstallPath(.bin, "Aether-3DS/Aether.3dsx"));
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

    // Engine unit tests (desktop only -- PSP/3DS/Switch pull in symbols that
    // can't be linked or analyzed under the test runner).
    if (resolved_config.platform != .psp and resolved_config.platform != .nintendo_3ds and resolved_config.platform != .nintendo_switch) {
        const mod_tests = b.addTest(.{
            .root_module = exe.root_module.import_table.get("aether").?,
        });
        const run_mod_tests = b.addRunArtifact(mod_tests);

        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&run_mod_tests.step);
    }
}
