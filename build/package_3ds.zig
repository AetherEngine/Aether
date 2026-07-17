const std = @import("std");
const zitrus = @import("zitrus");
const package_options = @import("package_options.zig");
const tools = @import("tool_options.zig");

const ExportOptions = package_options.ExportOptions;

pub fn pipeline(owner: *std.Build, b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) void {
    const zitrus_dep = owner.dependency("zitrus", .{});

    const elf_name = b.fmt("{s}.elf", .{exe.name});
    const install_elf = if (opts.output_dir) |dir|
        b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = b.fmt("bin/{s}", .{dir}) } },
            .dest_sub_path = elf_name,
        })
    else
        b.addInstallArtifact(exe, .{
            .dest_sub_path = elf_name,
        });
    b.getInstallStep().dependOn(&install_elf.step);

    const title = if (opts.title.len > 0) opts.title else exe.name;
    const publisher = if (opts.nintendo_3ds_publisher.len > 0) opts.nintendo_3ds_publisher else "Aether";
    const description = if (opts.nintendo_3ds_description.len > 0) opts.nintendo_3ds_description else title;
    const settings_zon = b.fmt(
        \\.{{
        \\    .titles = .{{
        \\        .english = .{{
        \\            .title = "{s}",
        \\            .description = "{s}",
        \\            .publisher = "{s}",
        \\        }},
        \\    }},
        \\}}
        \\
    , .{ title, description, publisher });

    const write_files = b.addWriteFiles();
    const smdh_settings = write_files.add("aether.smdh.zon", settings_zon);

    const smdh: zitrus.MakeSmdh = .initInner(b, .{
        .tools_artifact = zitrus_dep.artifact("zitrus"),
        .default_icon = zitrus_dep.path("assets/zitrus-logo-smdh.png"),
    }, .{
        .settings = smdh_settings,
        .icon = opts.nintendo_3ds_icon,
    });

    const romfs = if (opts.nintendo_3ds_romfs) |root| blk: {
        const make_romfs: zitrus.MakeRomFs = .initInner(b, .{
            .tools_artifact = zitrus_dep.artifact("zitrus"),
        }, .{
            .name = "romfs.bin",
            .root = root,
        });
        break :blk make_romfs.out;
    } else null;

    const final_3dsx: zitrus.Make3dsx = .initInner(b, .{
        .tools_artifact = zitrus_dep.artifact("zitrus"),
    }, .{
        .name = b.fmt("{s}.3dsx", .{exe.name}),
        .exe = exe,
        .smdh = smdh.out,
        .romfs = romfs,
    });
    final_3dsx.install(b, .{
        .install_dir = .bin,
        .dest_sub_path = if (opts.output_dir) |dir|
            b.fmt("{s}/{s}", .{ dir, final_3dsx.name })
        else
            final_3dsx.name,
    });
}

pub fn add3dslink(b: *std.Build, threedsx_path: []const u8) *std.Build.Step.Run {
    const dkp = tools.devkitProPath(b);
    const link_cmd = b.addSystemCommand(&.{b.pathJoin(&.{ dkp, "tools/bin/3dslink" })});
    if (b.option([]const u8, "3dslink-address", "3DS: target IP/hostname for 3dslink push (default: broadcast discovery)")) |ip| {
        link_cmd.addArgs(&.{ "-a", ip });
    }
    if (b.option(u32, "3dslink-retries", "3DS: 3dslink retry count")) |n| {
        link_cmd.addArgs(&.{ "-r", b.fmt("{d}", .{n}) });
    }
    if (b.option(bool, "3dslink-server", "3DS: pass -s so 3dslink stays listening after upload") orelse false) {
        link_cmd.addArg("-s");
    }
    link_cmd.addArg(threedsx_path);
    return link_cmd;
}
