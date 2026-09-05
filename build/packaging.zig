const std = @import("std");
const config_mod = @import("config.zig");
const macos = @import("package_macos.zig");
const options = @import("package_options.zig");
const psp = @import("package_psp.zig");
const switch_pkg = @import("package_switch.zig");
const threeds = @import("package_3ds.zig");
const web = @import("package_web.zig");
const windows = @import("package_windows.zig");

pub const ExportOptions = options.ExportOptions;
pub const Resource = options.Resource;

/// Outputs that callers may need after packaging an artifact.
pub const ExportResult = struct {
    /// The generated 3DSX, when targeting Nintendo 3DS. This remains a build
    /// graph output so it can be passed directly to Zitrus' Link3dsx step.
    nintendo_3dsx: ?std.Build.LazyPath = null,
};

/// Installs the game executable with platform-appropriate packaging.
///
/// This compatibility entry point discards any generated package outputs.
pub fn export_artifact(
    owner: *std.Build,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    config: config_mod.Config,
    opts: ExportOptions,
) void {
    _ = export_artifact_with_outputs(owner, b, exe, config, opts);
}

/// Installs the game executable with platform-appropriate packaging and
/// returns generated outputs that subsequent build steps can consume.
/// - PSP: ELF -> PRX -> SFO -> EBOOT.PBP pipeline.
/// - macOS: produces a `<name>.app` bundle under `zig-out/bin/`.
/// - Other desktop: plain `b.installArtifact`, plus any `opts.resources`
///   copied alongside the exe.
pub fn export_artifact_with_outputs(
    owner: *std.Build,
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    config: config_mod.Config,
    opts: ExportOptions,
) ExportResult {
    if (config.platform == .psp) {
        const psp_dep = owner.dependency("pspsdk", .{});
        _ = psp.eboot_pipeline(b, exe, psp_dep, opts);
    } else if (config.platform == .nintendo_3ds) {
        return .{ .nintendo_3dsx = threeds.pipeline(owner, b, exe, opts) };
    } else if (config.platform == .nintendo_switch) {
        switch_pkg.nro_pipeline(b, exe, opts);
    } else if (config.platform == .wasm) {
        const install = web.add_web_bundle(owner, b, exe, opts);
        b.getInstallStep().dependOn(&install.step);
    } else if (config.platform == .macos) {
        macos.app_bundle(b, exe, opts);
    } else {
        if (config.platform == .windows) {
            if (opts.windows_icon) |icon| windows.add_icon_resource(b, exe, icon);
        }
        b.installArtifact(exe);
        for (opts.resources) |res| {
            const install_res = b.addInstallBinFile(res.path, res.name);
            b.getInstallStep().dependOn(&install_res.step);
        }
    }

    return .{};
}

pub const add_web_bundle = web.add_web_bundle;
pub const add_serve_web_step = web.add_serve_web_step;
pub const Link3dsxOptions = threeds.Link3dsxOptions;
pub const add_link3dsx = threeds.add_link3dsx;
