const std = @import("std");
const pspsdk = @import("pspsdk");
const package_options = @import("package_options.zig");

const ExportOptions = package_options.ExportOptions;

/// Runs the ELF -> PRX -> SFO -> EBOOT.PBP pipeline. Resolves tool artifacts
/// from `psp_dep` but creates all build/install steps on `b` so they register
/// on the downstream project's builder.
pub fn ebootPipeline(b: *std.Build, exe: *std.Build.Step.Compile, psp_dep: *std.Build.Dependency, opts: ExportOptions) pspsdk.PspEboot {
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
