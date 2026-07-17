const std = @import("std");
const config_mod = @import("config.zig");
const tools = @import("tool_options.zig");

const Config = config_mod.Config;

const ShaderStagePaths = struct {
    vert: std.Build.LazyPath,
    frag: std.Build.LazyPath,
};

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

fn addSlangStep(b: *std.Build, slangc: std.Build.LazyPath, args: []const []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = std.Build.Step.Run.create(b, "slangc " ++ output_name);
    run.addFileArg(slangc);
    run.addArgs(args);
    run.addArg("-o");
    const output = run.addOutputFileArg(output_name);
    run.addFileArg(input);
    return output;
}

fn addSpirvCrossStep(b: *std.Build, spirv_cross: []const u8, args: []const []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{spirv_cross});
    run.setName("spirv-cross " ++ output_name);
    run.addFileArg(input);
    run.addArgs(args);
    run.addArg("--output");
    return run.addOutputFileArg(output_name);
}

fn addUamStep(b: *std.Build, uam: []const u8, stage: []const u8, comptime output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{ uam, "-s", stage, "-o" });
    const output = run.addOutputFileArg(output_name);
    run.addFileArg(input);
    return output;
}

pub fn addInternalShaderModule(owner: *std.Build, b: *std.Build, mod: *std.Build.Module, config: Config) void {
    const stages = internalShaderStages(owner, b, config) orelse return;

    mod.addAnonymousImport("aether_basic_vert", .{ .root_source_file = stages.vert });
    mod.addAnonymousImport("aether_basic_frag", .{ .root_source_file = stages.frag });
}

fn internalShaderStages(owner: *std.Build, b: *std.Build, config: Config) ?ShaderStagePaths {
    if (config.platform == .nintendo_3ds and config.gfx == .default) {
        return .{
            .vert = addZpshStep(owner, b, "basic.vert.zpsh", owner.path("src/platform/3ds/shaders/basic.zpsm")),
            .frag = b.addWriteFiles().add("basic.frag.3ds.stub", "3ds fixed-function fragment stage\n"),
        };
    }

    if (config.platform == .nintendo_switch and config.gfx == .default) {
        const uam = b.pathJoin(&.{ tools.devkitProPath(b), "tools/bin/uam" });
        const slangc = slangcPath(owner) orelse return null;
        const source = owner.path("src/rendering/shaders/basic.slang");
        const vert_glsl = addSlangStep(b, slangc, &.{
            "-target",       "glsl",       "-matrix-layout-column-major",
            "-DAETHER_DEKO", "-profile",   "glsl_450",
            "-entry",        "vertexMain", "-stage",
            "vertex",
        }, "basic.vert.switch.glsl", source);
        const frag_glsl = addSlangStep(b, slangc, &.{
            "-target",       "glsl",         "-matrix-layout-column-major",
            "-DAETHER_DEKO", "-profile",     "glsl_450",
            "-entry",        "fragmentMain", "-stage",
            "fragment",
        }, "basic.frag.switch.glsl", source);
        return .{
            .vert = addUamStep(
                b,
                uam,
                "vert",
                "basic.vert.dksh",
                vert_glsl,
            ),
            .frag = addUamStep(
                b,
                uam,
                "frag",
                "basic.frag.dksh",
                frag_glsl,
            ),
        };
    }

    switch (config.gfx) {
        .vulkan => {
            const slangc = slangcPath(owner) orelse return null;
            const source = owner.path("src/rendering/shaders/basic.slang");
            return .{
                .vert = addSlangStep(b, slangc, &.{
                    "-target",  "spirv",  "-emit-spirv-directly", "-matrix-layout-column-major",
                    "-DVULKAN", "-entry", "vertexMain",           "-stage",
                    "vertex",
                }, "basic.vert.spv", source),
                .frag = addSlangStep(b, slangc, &.{
                    "-target",  "spirv",  "-emit-spirv-directly", "-matrix-layout-column-major",
                    "-DVULKAN", "-entry", "fragmentMain",         "-stage",
                    "fragment",
                }, "basic.frag.spv", source),
            };
        },
        .opengl => {
            const slangc = slangcPath(owner) orelse return null;
            const source = owner.path("src/rendering/shaders/basic.slang");
            return .{
                .vert = addSlangStep(b, slangc, &.{
                    "-target",    "glsl",     "-matrix-layout-column-major",
                    "-profile",   "glsl_450", "-entry",
                    "vertexMain", "-stage",   "vertex",
                }, "basic.vert.glsl", source),
                .frag = addSlangStep(b, slangc, &.{
                    "-target",      "glsl",     "-matrix-layout-column-major",
                    "-profile",     "glsl_450", "-entry",
                    "fragmentMain", "-stage",   "fragment",
                }, "basic.frag.glsl", source),
            };
        },
        .webgl => {
            const slangc = slangcPath(owner) orelse return null;
            const spirv_cross = tools.spirvCrossPath(b);
            const source = owner.path("src/rendering/shaders/basic.slang");
            const vert_spv = addSlangStep(b, slangc, &.{
                "-entry",   "vertexMain", "-stage",               "vertex",
                "-profile", "glsl_330",   "-emit-spirv-via-glsl", "-matrix-layout-column-major",
            }, "basic.vert.webgl.spv", source);
            const frag_spv = addSlangStep(b, slangc, &.{
                "-entry",   "fragmentMain", "-stage",               "fragment",
                "-profile", "glsl_330",     "-emit-spirv-via-glsl", "-matrix-layout-column-major",
            }, "basic.frag.webgl.spv", source);
            return .{
                .vert = addSpirvCrossStep(b, spirv_cross, &.{
                    "--es",                        "--version",                   "300",
                    "--rename-interface-variable", "out",                         "0",
                    "v_uv",                        "--rename-interface-variable", "out",
                    "1",                           "v_color",                     "--rename-interface-variable",
                    "out",                         "2",                           "v_viewDepth",
                }, "basic.vert.webgl.glsl", vert_spv),
                .frag = addSpirvCrossStep(b, spirv_cross, &.{
                    "--es",                        "--version",                   "300",
                    "--rename-interface-variable", "in",                          "0",
                    "v_uv",                        "--rename-interface-variable", "in",
                    "1",                           "v_color",                     "--rename-interface-variable",
                    "in",                          "2",                           "v_viewDepth",
                }, "basic.frag.webgl.glsl", frag_spv),
            };
        },
        .default, .headless => return null,
    }
}

fn addZpshStep(owner: *std.Build, b: *std.Build, output_name: []const u8, input: std.Build.LazyPath) std.Build.LazyPath {
    const zitrus_dep = owner.dependency("zitrus", .{});
    const run = b.addRunArtifact(zitrus_dep.artifact("zitrus"));
    run.addArgs(&.{ "pica", "asm", "-o" });
    const output = run.addOutputFileArg(output_name);
    run.addFileArg(input);
    return output;
}
