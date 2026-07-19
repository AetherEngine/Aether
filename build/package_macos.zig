const std = @import("std");
const package_options = @import("package_options.zig");
const tools = @import("tool_options.zig");

const ExportOptions = package_options.ExportOptions;

/// Builds a `<exe.name>.app` directory under zig-out/bin/ with:
///   Contents/MacOS/<exe>                   -- patched load commands
///   Contents/Frameworks/libMoltenVK.dylib  -- id rewritten to @rpath
///   Contents/Info.plist                    -- minimum viable plist
///   Contents/Resources/<name>              -- opts.resources
///
/// After install, a post-install Run step invokes `codesign --force
/// --sign -` on each leaf dylib, then the exe, then the bundle dir.
/// --deep is intentionally avoided (deprecated, unreliable).
pub fn appBundle(b: *std.Build, exe: *std.Build.Step.Compile, opts: ExportOptions) void {
    const molten_vk_dir = tools.macosMoltenVkPath(b);

    const app_name = b.fmt("{s}.app", .{exe.name});

    // Each Run step takes the brew dylib as an input and writes a patched
    // copy to its own cache-managed output path, keeping zig's caching honest.
    const patched_moltenvk = patchDylibId(
        b,
        .{ .cwd_relative = b.pathJoin(&.{ molten_vk_dir, "libMoltenVK.dylib" }) },
        "libMoltenVK.dylib",
    );

    // Xcode 16+ install_name_tool exits non-zero when it invalidates an
    // existing code signature, so strip it first. codesign_allocate -r fixes
    // stricter __LINKEDIT size checks better than codesign --remove-signature.
    const patched_exe = b.addSystemCommand(&.{
        "sh", "-c",
        \\cp "$1" "$2"
        \\chmod +w "$2"
        \\if codesign_allocate -i "$2" -r -o "$2.tmp" 2>/dev/null; then
        \\  mv "$2.tmp" "$2"
        \\else
        \\  rm -f "$2.tmp"
        \\  codesign --remove-signature "$2" 2>/dev/null || true
        \\fi
        \\install_name_tool \
        \\  -change /opt/homebrew/opt/molten-vk/lib/libMoltenVK.dylib @rpath/libMoltenVK.dylib \
        \\  "$2"
        ,
        "sh",
    });
    patched_exe.addArtifactArg(exe);
    const exe_out = patched_exe.addOutputFileArg(exe.name);

    const icns_out: ?std.Build.LazyPath = if (opts.icon_png) |png| blk: {
        const gen = b.addSystemCommand(&.{
            "sh", "-c",
            \\set -euo pipefail
            \\IN="$1"; OUT="$2"
            \\T=$(mktemp -d -t aether_icns.XXXXXX)
            \\trap 'rm -rf "$T"' EXIT
            \\ISET="$T/AppIcon.iconset"; mkdir -p "$ISET"
            \\for spec in \
            \\  "16 icon_16x16.png" "32 icon_16x16@2x.png" \
            \\  "32 icon_32x32.png" "64 icon_32x32@2x.png" \
            \\  "128 icon_128x128.png" "256 icon_128x128@2x.png" \
            \\  "256 icon_256x256.png" "512 icon_256x256@2x.png" \
            \\  "512 icon_512x512.png" "1024 icon_512x512@2x.png"; do
            \\  set -- $spec; sz=$1; name=$2
            \\  sips -z "$sz" "$sz" "$IN" --out "$ISET/$name" >/dev/null
            \\done
            \\iconutil -c icns "$ISET" -o "$OUT"
            ,
            "sh",
        });
        gen.addFileArg(png);
        break :blk gen.addOutputFileArg("AppIcon.icns");
    } else null;

    const bundle_id = opts.bundle_id orelse b.fmt("com.aether.{s}", .{exe.name});
    const bundle_name = if (opts.title.len > 0) opts.title else exe.name;
    const icon_key = if (icns_out != null)
        "<key>CFBundleIconFile</key><string>AppIcon</string>"
    else
        "";
    const info_plist = b.fmt(
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0"><dict>
        \\  <key>CFBundleExecutable</key><string>{s}</string>
        \\  <key>CFBundleIdentifier</key><string>{s}</string>
        \\  <key>CFBundleName</key><string>{s}</string>
        \\  <key>CFBundlePackageType</key><string>APPL</string>
        \\  <key>CFBundleShortVersionString</key><string>0.0.0</string>
        \\  <key>CFBundleVersion</key><string>0</string>
        \\  <key>LSMinimumSystemVersion</key><string>11.0</string>
        \\  <key>NSHighResolutionCapable</key><true/>
        \\  {s}
        \\</dict></plist>
        \\
    , .{ exe.name, bundle_id, bundle_name, icon_key });

    const app_tree = b.addWriteFiles();
    _ = app_tree.addCopyFile(exe_out, b.fmt("Contents/MacOS/{s}", .{exe.name}));
    _ = app_tree.addCopyFile(patched_moltenvk, "Contents/Frameworks/libMoltenVK.dylib");
    _ = app_tree.add("Contents/Info.plist", info_plist);
    if (icns_out) |icns| _ = app_tree.addCopyFile(icns, "Contents/Resources/AppIcon.icns");
    for (opts.resources) |res| {
        _ = app_tree.addCopyFile(res.path, b.fmt("Contents/Resources/{s}", .{res.name}));
    }

    const install = b.addInstallDirectory(.{
        .source_dir = app_tree.getDirectory(),
        .install_dir = .bin,
        .install_subdir = app_name,
    });
    b.getInstallStep().dependOn(&install.step);

    // Must run after install_name_tool is long done. Sign leaves first, then
    // the exe, then the bundle dir.
    const bundle_path = b.getInstallPath(.bin, app_name);
    const sign = b.addSystemCommand(&.{ "sh", "-c", b.fmt(
        "codesign --force --sign - \"{s}/Contents/Frameworks/libMoltenVK.dylib\" && " ++
            "codesign --force --sign - \"{s}/Contents/MacOS/{s}\" && " ++
            "codesign --force --sign - \"{s}\"",
        .{ bundle_path, bundle_path, exe.name, bundle_path },
    ) });
    sign.step.dependOn(&install.step);
    b.getInstallStep().dependOn(&sign.step);
}

/// Copies a dylib into the build cache and rewrites its LC_ID_DYLIB to
/// `@rpath/<basename>` so it can be loaded from `Contents/Frameworks/`.
fn patchDylibId(b: *std.Build, src: std.Build.LazyPath, basename: []const u8) std.Build.LazyPath {
    // Homebrew dylibs are ad-hoc signed. Xcode 16+ install_name_tool exits
    // non-zero when it invalidates that signature, so strip it first.
    const patch = b.addSystemCommand(&.{
        "sh", "-c",
        b.fmt(
            \\cp "$1" "$2"
            \\chmod +w "$2"
            \\if codesign_allocate -i "$2" -r -o "$2.tmp" 2>/dev/null; then
            \\  mv "$2.tmp" "$2"
            \\else
            \\  rm -f "$2.tmp"
            \\  codesign --remove-signature "$2" 2>/dev/null || true
            \\fi
            \\install_name_tool -id @rpath/{s} "$2"
        ,
            .{basename},
        ),
        "sh",
    });
    patch.addFileArg(src);
    return patch.addOutputFileArg(basename);
}
