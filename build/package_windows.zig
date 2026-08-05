const std = @import("std");

/// Adds an ICO icon to the PE resource table. Zig's built-in resource compiler
/// runs on every host, so Windows executables can be cross-compiled with their
/// application icon intact.
pub fn addIconResource(b: *std.Build, exe: *std.Build.Step.Compile, icon: std.Build.LazyPath) void {
    const resources = b.addWriteFiles();
    _ = resources.addCopyFile(icon, "AppIcon.ico");
    const rc = resources.add("AppIcon.rc",
        \\1 ICON "AppIcon.ico"
        \\
    );
    exe.root_module.addWin32ResourceFile(.{ .file = rc });
}
