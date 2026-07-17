const std = @import("std");
const package_options = @import("package_options.zig");

const ExportOptions = package_options.ExportOptions;

pub fn addWebBundle(owner: *std.Build, b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) *std.Build.Step.InstallDir {
    const web = b.addWriteFiles();
    _ = web.addCopyFile(exe.getEmittedBin(), opts.web_wasm_name);
    _ = web.addCopyFile(owner.path("web/index.html"), "index.html");
    _ = web.addCopyFile(owner.path("web/aether.js"), "aether.js");
    _ = web.add("resources.manifest", opts.web_resource_manifest);
    if (opts.web_resources) |resource_dir| {
        _ = web.addCopyDirectory(resource_dir, "", .{});
    }
    for (opts.web_resource_files) |res| {
        _ = web.addCopyFile(res.path, res.name);
    }

    return b.addInstallDirectory(.{
        .source_dir = web.getDirectory(),
        .install_dir = .prefix,
        .install_subdir = "web",
    });
}

pub fn addServeWebStep(
    owner: *std.Build,
    b: *std.Build,
    name: []const u8,
    web_install: *std.Build.Step.InstallDir,
    host: []const u8,
    port: u16,
) *std.Build.Step.Run {
    const serve_web_exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = owner.path("tools/serve_web.zig"),
            .target = b.resolveTargetQuery(.{}),
            .optimize = .Debug,
        }),
    });
    const serve_web_cmd = b.addRunArtifact(serve_web_exe);
    serve_web_cmd.step.dependOn(&web_install.step);
    serve_web_cmd.addArg(b.getInstallPath(.prefix, "web"));
    serve_web_cmd.addArg(host);
    serve_web_cmd.addArg(b.fmt("{d}", .{port}));
    return serve_web_cmd;
}
