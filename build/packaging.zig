const std = @import("std");
const config_mod = @import("config.zig");
const macos = @import("package_macos.zig");
const options = @import("package_options.zig");
const psp = @import("package_psp.zig");
const switch_pkg = @import("package_switch.zig");
const threeds = @import("package_3ds.zig");
const web = @import("package_web.zig");

pub const ExportOptions = options.ExportOptions;
pub const Resource = options.Resource;

/// Installs the game executable with platform-appropriate packaging.
/// - PSP: ELF -> PRX -> SFO -> EBOOT.PBP pipeline.
/// - macOS: produces a `<name>.app` bundle under `zig-out/bin/`.
/// - Other desktop: plain `b.installArtifact`, plus any `opts.resources`
///   copied alongside the exe.
pub fn exportArtifact(
    owner: *std.Build,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    config: config_mod.Config,
    opts: ExportOptions,
) void {
    if (config.platform == .psp) {
        const psp_dep = owner.dependency("pspsdk", .{});
        _ = psp.ebootPipeline(b, exe, psp_dep, opts);
    } else if (config.platform == .nintendo_3ds) {
        threeds.pipeline(owner, b, exe, opts);
    } else if (config.platform == .nintendo_switch) {
        switch_pkg.nroPipeline(b, exe, opts);
    } else if (config.platform == .wasm) {
        const install = web.addWebBundle(owner, b, exe, opts);
        b.getInstallStep().dependOn(&install.step);
    } else if (config.platform == .macos) {
        macos.appBundle(b, exe, opts);
    } else {
        b.installArtifact(exe);
        for (opts.resources) |res| {
            const install_res = b.addInstallBinFile(res.path, res.name);
            b.getInstallStep().dependOn(&install_res.step);
        }
    }
}

pub const addWebBundle = web.addWebBundle;
pub const addServeWebStep = web.addServeWebStep;
pub const add3dslink = threeds.add3dslink;
