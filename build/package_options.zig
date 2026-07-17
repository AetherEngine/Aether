const std = @import("std");

pub const ExportOptions = struct {
    /// PSP/macOS: human-readable name shown to the OS (XMB title on PSP,
    /// CFBundleName on macOS). Ignored elsewhere.
    title: []const u8 = "",
    /// PSP/3DS/Switch: subdirectory under zig-out/bin/ for packaged artifacts.
    output_dir: ?[]const u8 = null,
    /// PSP: optional PBP assets.
    icon0: ?std.Build.LazyPath = null,
    icon1: ?std.Build.LazyPath = null,
    pic0: ?std.Build.LazyPath = null,
    pic1: ?std.Build.LazyPath = null,
    snd0: ?std.Build.LazyPath = null,
    /// macOS: reverse-DNS bundle identifier for Info.plist (CFBundleIdentifier).
    /// Defaults to "com.aether.<exe-name>".
    bundle_id: ?[]const u8 = null,
    /// macOS: PNG icon to use for the bundle.
    icon_png: ?std.Build.LazyPath = null,
    /// Files to install into the app bundle. On macOS they land under
    /// `Contents/Resources/<name>`. On desktop non-macOS they are copied
    /// alongside the exe in `zig-out/bin/`. Ignored on PSP.
    resources: []const Resource = &.{},
    /// WASM/browser: directory copied into the web artifact root and exposed
    /// through `resources.manifest` for the JavaScript WASI preloader.
    web_resources: ?std.Build.LazyPath = null,
    /// WASM/browser: individual files copied into the web artifact root.
    web_resource_files: []const Resource = &.{},
    /// WASM/browser: newline-delimited resource paths relative to
    /// `web_resources`.
    web_resource_manifest: []const u8 = "",
    /// WASM/browser: destination wasm filename. Defaults to the name expected
    /// by the stock Aether web loader.
    web_wasm_name: []const u8 = "Aether.wasm",
    /// Switch: NACP author string (shows under the title in the HOME menu).
    /// Empty falls back to "Aether".
    switch_author: []const u8 = "",
    /// Switch: NACP version string (e.g. "1.0.0"). Empty falls back to
    /// "1.0.0".
    switch_version: []const u8 = "",
    /// Switch: 256x256 JPEG icon embedded in the NRO. When null, libnx's
    /// `default_icon.jpg` is used.
    switch_icon: ?std.Build.LazyPath = null,
    /// Switch: directory embedded into the NRO as RomFS. When null, no RomFS is
    /// attached.
    switch_romfs: ?std.Build.LazyPath = null,
    /// 3DS: publisher string embedded in SMDH metadata. Empty falls back to
    /// "Aether".
    nintendo_3ds_publisher: []const u8 = "",
    /// 3DS: description string embedded in SMDH metadata. Empty falls back to
    /// the title.
    nintendo_3ds_description: []const u8 = "",
    /// 3DS: 48x48 icon embedded in SMDH metadata. When null, Zitrus' default
    /// icon is used.
    nintendo_3ds_icon: ?std.Build.LazyPath = null,
    /// 3DS: directory embedded into the 3DSX as RomFS. When null, no RomFS is
    /// attached.
    nintendo_3ds_romfs: ?std.Build.LazyPath = null,
};

pub const Resource = struct {
    /// Source file to copy.
    path: std.Build.LazyPath,
    /// Destination name inside Resources/ (or alongside exe on non-mac).
    name: []const u8,
};
