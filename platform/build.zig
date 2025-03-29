const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const platform_opt = b.option([]const u8, "platform", "Platform to build for") orelse "";

    const options = b.addOptions();
    options.addOption([]const u8, "platform", platform_opt);

    const option_mod = options.createModule();

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("options", option_mod);

    const lib = b.addLibrary(.{
        .name = "platform",
        .root_module = lib_mod,
    });
    b.installArtifact(lib);
}
