//! Enforce source ownership without compiling target-specific SDK code.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer args.deinit();

    _ = args.next();
    const repository_path = args.next() orelse ".";

    var repository_dir = try std.Io.Dir.cwd().openDir(io, repository_path, .{});
    defer repository_dir.close(io);

    if (!try check_repository(alloc, io, repository_dir, true)) return error.ArchitectureViolation;
}

fn check_repository(alloc: std.mem.Allocator, io: std.Io, repository_dir: std.Io.Dir, report: bool) !bool {
    var valid = true;
    // Open only engine-owned trees. Walking the repository itself would also
    // inspect generated code, cached dependencies, tools, and sample apps.
    for ([_][]const u8{ "core", "platform", "src" }) |tree| {
        var source_dir = repository_dir.openDir(io, tree, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => {
                if (std.mem.eql(u8, tree, "src")) continue;
                return err;
            },
            else => return err,
        };
        defer source_dir.close(io);

        var walker = try source_dir.walkSelectively(alloc);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind == .directory) {
                if (!ignored_directory(entry.basename)) try walker.enter(io, entry);
                continue;
            }
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
            // Use slash-separated paths for the same checks on every host OS.
            const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ tree, entry.path });
            defer alloc.free(path);

            std.mem.replaceScalar(u8, path, '\\', '/');
            if (std.mem.eql(u8, tree, "src")) {
                if (report) std.debug.print("{s}: engine sources must live in top-level core/ or platform/\n", .{path});
                valid = false;
                continue;
            }

            const bytes = try source_dir.readFileAlloc(io, entry.path, alloc, .limited(4 * 1024 * 1024));
            defer alloc.free(bytes);

            const source = try alloc.dupeZ(u8, bytes);
            defer alloc.free(source);

            if (!try check_source(alloc, path, source, report)) valid = false;
        }
    }
    return valid;
}

fn ignored_directory(name: []const u8) bool {
    inline for (.{ ".git", ".zig-cache", "zig-cache", "zig-out", "node_modules" }) |ignored| {
        if (std.mem.eql(u8, name, ignored)) return true;
    }
    return false;
}

fn check_source(alloc: std.mem.Allocator, path: []const u8, source: [:0]const u8, report: bool) !bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var valid = true;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .builtin or !std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import")) continue;
        if (tokenizer.next().tag != .l_paren) continue;
        const literal = tokenizer.next();
        if (literal.tag != .string_literal) continue;
        const import_path = try std.zig.string_literal.parseAlloc(alloc, source[literal.loc.start..literal.loc.end]);
        defer alloc.free(import_path);

        if (!try allowed_import(alloc, path, import_path)) {
            if (report) std.debug.print("{s}: import of '{s}' crosses the Core/Platform boundary\n", .{ path, import_path });
            valid = false;
        }
    }
    return valid;
}

fn allowed_import(alloc: std.mem.Allocator, path: []const u8, import_path: []const u8) !bool {
    if (std.mem.endsWith(u8, import_path, ".zig")) {
        const parent = std.fs.path.dirname(path) orelse ".";
        const normalized = try alloc.dupe(u8, import_path);
        defer alloc.free(normalized);

        std.mem.replaceScalar(u8, normalized, '\\', '/');
        const resolved = try std.fs.path.resolvePosix(alloc, &.{ "/", parent, normalized });
        defer alloc.free(resolved);

        // Entry modules compose the engine and application. Importing one
        // from an ordinary module would hide a dependency on those roots.
        if (is_entry(resolved[1..]) and !is_entry(path)) return false;
        if (std.mem.startsWith(u8, path, "platform/")) {
            return std.mem.startsWith(u8, resolved, "/platform/");
        }
        if (std.mem.startsWith(u8, path, "core/")) {
            // Platform is a separately wired Zig module, including its
            // shared types. Core crosses that boundary only by module name.
            return std.mem.startsWith(u8, resolved, "/core/");
        }
    } else if (std.mem.startsWith(u8, path, "platform/") or std.mem.startsWith(u8, path, "core/")) {
        // Executable roots compose the application and engine. Backend modules
        // must never reach through these named imports into the engine API.
        inline for (.{ "core", "aether", "aether_user_root", "aether_entry_common", "root" }) |name| {
            if (std.mem.eql(u8, import_path, name)) return allowed_entry_import(path, import_path);
        }
        if (std.mem.startsWith(u8, path, "core/")) {
            // These build-provided modules expose backend SDKs. Core uses
            // shared Platform contracts instead of talking to them directly.
            inline for (.{ "sdl3", "vulkan", "gl", "pspsdk", "zitrus" }) |name| {
                if (std.mem.eql(u8, import_path, name)) return false;
            }
        }
    }
    return true;
}

fn allowed_entry_import(path: []const u8, import_path: []const u8) bool {
    const EntryImport = struct { path: []const u8, module: []const u8 };
    inline for ([_]EntryImport{
        .{ .path = "platform/entry.zig", .module = "aether_entry_common" },
        .{ .path = "platform/entry_common.zig", .module = "aether" },
        .{ .path = "platform/entry_common.zig", .module = "aether_user_root" },
        .{ .path = "platform/psp/entry.zig", .module = "aether_entry_common" },
        .{ .path = "platform/3ds/entry.zig", .module = "aether" },
        .{ .path = "platform/3ds/entry.zig", .module = "aether_entry_common" },
        .{ .path = "platform/switch/services.zig", .module = "aether" },
        .{ .path = "platform/switch/services.zig", .module = "aether_entry_common" },
    }) |entry| {
        if (std.mem.eql(u8, path, entry.path) and std.mem.eql(u8, import_path, entry.module)) return true;
    }
    return false;
}

fn is_entry(path: []const u8) bool {
    inline for (.{
        "platform/entry.zig",
        "platform/entry_common.zig",
        "platform/psp/entry.zig",
        "platform/3ds/entry.zig",
        "platform/switch/services.zig",
    }) |entry| {
        if (std.mem.eql(u8, path, entry)) return true;
    }
    return false;
}

test "platform dependencies stay below Core and Core uses the named platform module" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try allowed_import(alloc, "platform/sdl/input.zig", "../input_api.zig"));
    try std.testing.expect(!try allowed_import(alloc, "platform/sdl/input.zig", "../../core/input/input.zig"));
    try std.testing.expect(!try allowed_import(alloc, "platform/gfx.zig", "../root.zig"));
    try std.testing.expect(!try allowed_import(alloc, "platform/gfx.zig", "../core/root.zig"));
    try std.testing.expect(!try allowed_import(alloc, "platform/gfx.zig", "core"));
    try std.testing.expect(!try allowed_import(alloc, "platform/gfx.zig", "aether"));
    try std.testing.expect(try allowed_import(alloc, "platform/3ds/entry.zig", "aether"));
    try std.testing.expect(try allowed_import(alloc, "core/engine.zig", "platform"));
    try std.testing.expect(try allowed_import(alloc, "core/root.zig", "core.zig"));
    try std.testing.expect(try allowed_import(alloc, "core/root.zig", "platform"));
    try std.testing.expect(try allowed_import(alloc, "core/input/input.zig", "../resources.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/engine.zig", "../platform/platform.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/engine.zig", "../platform/sdl/surface.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/input/input.zig", "../../platform/input_api.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/input/input.zig", "../../platform/input/frame.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/root.zig", "../tools/check_architecture.zig"));
}

test "comments and strings are not imports" {
    try std.testing.expect(try check_source(std.testing.allocator, "platform/gfx.zig",
        \\// @import("../core/engine.zig")
        \\const example = "@import(\"../core/engine.zig\")";
        \\const std = @import("std");
    , false));
}

test "Core cannot import SDKs or application roots by module name" {
    const alloc = std.testing.allocator;
    inline for (.{ "std", "builtin", "options" }) |name| {
        try std.testing.expect(try allowed_import(alloc, "core/engine.zig", name));
    }
    inline for (.{ "sdl3", "vulkan", "gl", "pspsdk", "zitrus", "core", "aether", "aether_user_root", "aether_entry_common", "root" }) |name| {
        try std.testing.expect(!try allowed_import(alloc, "core/engine.zig", name));
    }
    try std.testing.expect(try allowed_import(alloc, "platform/3ds/gfx.zig", "zitrus"));
}

test "bootstrap exceptions are limited to the required file and module pairs" {
    const alloc = std.testing.allocator;
    try std.testing.expect(try allowed_import(alloc, "platform/entry_common.zig", "aether_user_root"));
    try std.testing.expect(try allowed_import(alloc, "platform/switch/services.zig", "aether_entry_common"));
    try std.testing.expect(!try allowed_import(alloc, "platform/switch/services.zig", "aether_user_root"));
    try std.testing.expect(!try allowed_import(alloc, "platform/psp/entry.zig", "aether"));
    try std.testing.expect(!try allowed_import(alloc, "platform/entry_common.zig", "root"));
    try std.testing.expect(!try allowed_import(alloc, "platform/entry_common.zig", "core"));
    try std.testing.expect(!try allowed_import(alloc, "platform/3ds/entry.zig", "core"));
    try std.testing.expect(!try allowed_import(alloc, "platform/sdl/entry.zig", "aether"));
    try std.testing.expect(!try allowed_import(alloc, "platform/gfx.zig", "entry_common.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/engine.zig", "../platform/entry_common.zig"));
}

test "relative traversal cannot bypass layer or backend checks" {
    const alloc = std.testing.allocator;
    try std.testing.expect(!try allowed_import(alloc, "platform/sdl/gfx.zig", "../util/../../core/engine.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/engine.zig", "../platform/util/../sdl/surface.zig"));
    try std.testing.expect(!try allowed_import(alloc, "platform/sdl/gfx.zig", "../util/../entry_common.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/input/input.zig", "../../platform/math/../input/data.zig"));
    try std.testing.expect(!try allowed_import(alloc, "platform/sdl/gfx.zig", "..\\..\\core\\root.zig"));
    try std.testing.expect(!try allowed_import(alloc, "core/input/input.zig", "..\\..\\platform\\input_api.zig"));
    try std.testing.expect(try allowed_import(alloc, "core/input/input.zig", "..\\input\\action.zig"));
}

test "repository scan limits ownership checks to engine trees and rejects legacy src files" {
    const alloc = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    inline for (.{ "core", "platform", "tools", ".zig-cache/dependencies", "platform/.zig-cache/dependencies", "zig-out", "src/old" }) |path| {
        try tmp.dir.createDirPath(io, path);
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "core/root.zig", .data = "const platform = @import(\"platform\");" });
    try tmp.dir.writeFile(io, .{ .sub_path = "platform/platform.zig", .data = "const std = @import(\"std\");" });
    inline for (.{ "tools", ".zig-cache/dependencies", "platform/.zig-cache/dependencies", "zig-out" }) |path| {
        try tmp.dir.writeFile(io, .{ .sub_path = path ++ "/foreign.zig", .data = "const engine = @import(\"aether\");" });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "src/old/notes.txt", .data = "Legacy assets do not count as engine code." });
    try std.testing.expect(try check_repository(alloc, io, tmp.dir, false));

    try tmp.dir.writeFile(io, .{ .sub_path = "src/old/engine.zig", .data = "" });
    try std.testing.expect(!try check_repository(alloc, io, tmp.dir, false));
}
