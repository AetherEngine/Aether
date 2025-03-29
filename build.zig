const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const platform_opt = b.option([]const u8, "platform", "Platform to build for") orelse "";
    const platform = b.dependency("aether_platform", .{
        .platform = platform_opt,
    });

    // Expose Library Module
    const lib_mod = b.addModule("aether", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.addImport("platform", platform.artifact("platform").root_module);

    const lib_unit_tests = b.addTest(.{
        .root_module = lib_mod,
    });

    // Testing
    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // Coverage
    const cov_step = b.step("cov", "Generate coverage report");
    const run_cover = b.addSystemCommand(&.{
        "kcov",
        "--clean",
        "--include-pattern=src/",
        "--dump-summary",
        "./coverage",
    });
    run_cover.addArtifactArg(lib_unit_tests);
    cov_step.dependOn(&run_cover.step);
}
