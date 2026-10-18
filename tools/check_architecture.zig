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

            const source = try alloc.dupeSentinel(u8, bytes, 0);
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

        // Executable roots are separate modules. They reach Platform and the
        // application only by module name, and nothing imports them by path:
        // either direction would place one file in two modules.
        if (is_root(path) or is_root(resolved[1..])) return false;
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
        inline for (.{ "core", "aether", "aether_user_root", "aether_app", "root" }) |name| {
            if (std.mem.eql(u8, import_path, name)) return allowed_root_import(path, import_path);
        }
        if (std.mem.eql(u8, import_path, "platform") and std.mem.startsWith(u8, path, "platform/")) {
            return allowed_root_import(path, import_path);
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

/// `root/common.zig` adapts the application; each target root composes
/// Platform's entry with that adapter.
fn allowed_root_import(path: []const u8, import_path: []const u8) bool {
    if (!is_root(path)) return false;
    if (std.mem.eql(u8, path, "platform/root/common.zig")) {
        return std.mem.eql(u8, import_path, "aether") or std.mem.eql(u8, import_path, "aether_user_root");
    }
    return std.mem.eql(u8, import_path, "platform") or std.mem.eql(u8, import_path, "aether_app");
}

fn is_root(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "platform/root/");
}
