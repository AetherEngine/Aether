const std = @import("std");
const package_options = @import("package_options.zig");
const tools = @import("tool_options.zig");

const ExportOptions = package_options.ExportOptions;

fn cBackendOptimizeMode(exe: *std.Build.Step.Compile) std.builtin.OptimizeMode {
    return exe.root_module.optimize orelse .Debug;
}

fn cBackendGccOptimizeArg(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe, .ReleaseFast => "-O2",
        .ReleaseSmall => "-Os",
    };
}

fn cBackendGccDebugArg(optimize: std.builtin.OptimizeMode) []const u8 {
    return if (optimize == .Debug or optimize == .ReleaseSafe) "-g" else "-g0";
}

/// Compiles the zig-emitted C with devkitA64, links against libnx, and
/// packages the ELF plus a NACP and optional RomFS into a `.nro` homebrew
/// bundle.
pub fn nroPipeline(b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) void {
    // aarch64 GCC supports __int128 natively, so we don't need the `zig.h`
    // integer-alignment patch used by old 32-bit ARM C pipelines. We do still
    // need a compiler_rt object because zig.h calls helpers like
    // `__floatunsisf` / `__floatundidf` / `__floatdisf` unconditionally, but
    // devkitA64's libgcc doesn't ship them. GCC on aarch64 with hardware FP
    // inlines these casts, so the helpers are dead code in normal
    // compilations. Zig's emitted C takes the slow path, so we drop in zig's
    // own compiler_rt to satisfy the references.
    const game_target = exe.root_module.resolved_target.?;
    var crt_query = game_target.query;
    crt_query.os_tag = .freestanding;
    crt_query.ofmt = null;
    crt_query.cpu_model = .{ .explicit = game_target.result.cpu.model };
    const crt_target = b.resolveTargetQuery(crt_query);

    const compiler_rt_path = b.pathJoin(&.{
        b.graph.zig_lib_directory.path orelse ".",
        "compiler_rt.zig",
    });
    const crt_obj = b.addObject(.{
        .name = "aether_switch_compiler_rt",
        .root_module = b.createModule(.{
            .root_source_file = .{ .cwd_relative = compiler_rt_path },
            .target = crt_target,
            .optimize = .ReleaseSmall,
            .strip = true,
            // Switch homebrew uses libnx's switch.specs which links with
            // `-z text`. PIC is mandatory for any object that ends up in the
            // read-only .text segment.
            .pic = true,
        }),
    });

    const dkp = tools.devkitProPath(b);

    const strip_libc = b.addSystemCommand(&.{
        b.pathJoin(&.{ dkp, "devkitA64/bin/aarch64-none-elf-objcopy" }),
        "--localize-symbol=memset",
        "--localize-symbol=memcpy",
        "--localize-symbol=memmove",
        "--localize-symbol=memcmp",
        "--localize-symbol=strlen",
        "--localize-symbol=bcmp",
    });
    strip_libc.addArtifactArg(crt_obj);
    const crt_clean = strip_libc.addOutputFileArg("aether_switch_compiler_rt.o");
    const gcc = b.pathJoin(&.{ dkp, "devkitA64/bin/aarch64-none-elf-gcc" });
    const tool_elf2nro = b.pathJoin(&.{ dkp, "tools/bin/elf2nro" });
    const tool_nacp = b.pathJoin(&.{ dkp, "tools/bin/nacptool" });
    const libnx_inc = b.pathJoin(&.{ dkp, "libnx/include" });
    const libnx_lib = b.pathJoin(&.{ dkp, "libnx/lib" });
    const libnx_specs = b.pathJoin(&.{ dkp, "libnx/switch.specs" });
    const default_icon = b.pathJoin(&.{ dkp, "libnx/default_icon.jpg" });

    const syms_wf = b.addWriteFiles();
    const text_syms_ld = syms_wf.add("aether_switch_text_syms.ld",
        \\/* Zig C backend (for Switch ofmt=c) mangles extern names with zig_e_ prefix. */
        \\zig_e___text_start = ADDR(.text);
        \\zig_e___text_end = ADDR(.text) + SIZEOF(.text);
        \\__text_start = zig_e___text_start;
        \\__text_end = zig_e___text_end;
    );

    // Standard Switch arch flags from devkitPro's switch_rules / example
    // Makefiles. `-mtp=soft` matches what libnx is built against; mismatching
    // the TLS access mode crashes on the first thread-local read.
    const arch = [_][]const u8{
        "-march=armv8-a+crc+crypto", "-mtune=cortex-a57", "-mtp=soft", "-fPIE", "-fno-omit-frame-pointer",
    };

    const exe_optimize = cBackendOptimizeMode(exe);

    const link = b.addSystemCommand(&.{gcc});
    link.addArgs(&arch);
    link.addArgs(&.{
        "-ffunction-sections",
        "-fdata-sections",
        "-D_FORTIFY_SOURCE=0",
        "-D__SWITCH__",
        cBackendGccOptimizeArg(exe_optimize),
        cBackendGccDebugArg(exe_optimize),
        b.fmt("-specs={s}", .{libnx_specs}),
        "-T",
    });
    link.addFileArg(text_syms_ld);
    link.addArgs(&.{
        "-std=gnu11",
        // zig's -ofmt=c emitter has known pointer/int-conversion mismatches
        // that gcc 14+ promotes to errors. We don't author the C, so demote
        // them.
        "-fno-strict-aliasing",
        "-Wno-incompatible-pointer-types",
        "-Wno-int-conversion",
        "-Wno-builtin-declaration-mismatch",
    });
    link.addArg(b.fmt("-I{s}", .{libnx_inc}));
    // zig's emitted C `#include "zig.h"`. The header lives in zig's own lib
    // directory; point gcc at it.
    link.addArg(b.fmt("-I{s}", .{b.graph.zig_lib_directory.path orelse "."}));
    link.addArg("-x");
    link.addArg("c");
    link.addArtifactArg(exe);
    link.addArg("-x");
    link.addArg("none");
    link.addFileArg(crt_clean);
    link.addArg(b.fmt("-L{s}", .{libnx_lib}));
    link.addArgs(&.{ "-ldeko3d", "-lnx", "-lm" });
    link.addArg("-o");
    const elf = link.addOutputFileArg(b.fmt("{s}.elf", .{exe.name}));

    // NACP metadata (HOME-menu title, author, version).
    const nacp_run = b.addSystemCommand(&.{ tool_nacp, "--create" });
    nacp_run.addArg(if (opts.title.len > 0) opts.title else exe.name);
    nacp_run.addArg(if (opts.switch_author.len > 0) opts.switch_author else "Aether");
    nacp_run.addArg(if (opts.switch_version.len > 0) opts.switch_version else "1.0.0");
    const nacp = nacp_run.addOutputFileArg(b.fmt("{s}.nacp", .{exe.name}));

    // ELF -> NRO. The icon, NACP, and optional RomFS ride in via flag-form
    // args.
    const pack = b.addSystemCommand(&.{tool_elf2nro});
    pack.addFileArg(elf);
    const nro = pack.addOutputFileArg(b.fmt("{s}.nro", .{exe.name}));
    if (opts.switch_icon) |icon|
        pack.addPrefixedFileArg("--icon=", icon)
    else
        pack.addArg(b.fmt("--icon={s}", .{default_icon}));
    pack.addPrefixedFileArg("--nacp=", nacp);
    if (opts.switch_romfs) |r| pack.addPrefixedDirectoryArg("--romfsdir=", r);

    if (opts.output_dir) |dir| {
        const alloc = b.allocator;
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            nro,
            std.mem.concat(alloc, u8, &.{ dir, "/", exe.name, ".nro" }) catch @panic("OOM"),
        ).step);
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            elf,
            std.mem.concat(alloc, u8, &.{ dir, "/", exe.name, ".elf" }) catch @panic("OOM"),
        ).step);
    } else {
        b.getInstallStep().dependOn(&b.addInstallBinFile(
            nro,
            b.fmt("{s}.nro", .{exe.name}),
        ).step);
    }
}
