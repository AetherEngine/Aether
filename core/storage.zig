//! Bounded settings I/O and replacement writes. Callers serialize writes to a
//! destination and reserve its .aether-tmp/.aether-previous sibling names.
const std = @import("std");
const filesystem = @import("platform").filesystem;

pub const ReplaceOptions = struct {
    strategy: enum { platform_default, replace, backup } = .platform_default,
    /// Flush file contents to storage before promotion. Directory metadata is
    /// not synced; this is not a promise of crash-atomic durable replacement.
    sync_file: bool = false,
};

pub const ReplaceResult = struct {
    bytes: u64,
    /// The new file is active, but cleanup of .aether-previous failed.
    previous_retained: bool = false,
};

/// body.write(*std.Io.Writer) writes the replacement. Existing temporary or
/// backup files are never removed/overwritten blindly. RollbackFailed preserves
/// both files for recovery; other failures attempt to remove only our new
/// temporary file. Destinations must be absent or regular files: directories,
/// symlinks (including dangling links), and other special files are rejected.
/// Parent directories and the reserved sibling paths must not change during the
/// operation; this API does not provide synchronization with external writers.
pub fn write_replace(io: std.Io, dir: std.Io.Dir, path: []const u8, body: anytype, opts: ReplaceOptions) !ReplaceResult {
    return write_replace_using(io, dir, path, body, opts, NativeOperations{ .io = io });
}

fn write_replace_using(io: std.Io, dir: std.Io.Dir, path: []const u8, body: anytype, opts: ReplaceOptions, operations: anytype) !ReplaceResult {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    var temp_buf: [filesystem.max_path_bytes]u8 = undefined;
    var previous_buf: [filesystem.max_path_bytes]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buf, "{s}.aether-tmp", .{path});
    const previous = try std.fmt.bufPrint(&previous_buf, "{s}.aether-previous", .{path});
    const replace = switch (opts.strategy) {
        .platform_default => filesystem.rename_replaces_destination,
        .replace => true,
        .backup => false,
    };
    if (!replace and try exists(io, dir, previous)) return error.BackupExists;
    _ = try valid_destination(io, dir, path);

    const file = try dir.createFile(io, temp, .{ .exclusive = true });
    var keep_temp = false;
    errdefer if (!keep_temp) dir.deleteFile(io, temp) catch {};
    const bytes = blk: {
        defer file.close(io);

        var buffer: [4096]u8 = undefined;
        var writer = file.writer(io, &buffer);
        try body.write(&writer.interface);
        try writer.interface.flush();
        if (opts.sync_file) try file.sync(io);
        break :blk (try file.stat(io)).size;
    };

    const destination_exists = try valid_destination(io, dir, path);
    if (replace or !destination_exists) {
        try operations.rename(dir, temp, path);
        return .{ .bytes = bytes };
    }
    // Recheck after the callback has run; it may have performed application I/O.
    if (try exists(io, dir, previous)) return error.BackupExists;
    try operations.rename(dir, path, previous);
    operations.rename(dir, temp, path) catch |err| {
        operations.rename(dir, previous, path) catch {
            keep_temp = true;
            return error.RollbackFailed;
        };
        return err;
    };
    operations.delete_previous(dir, previous) catch return .{ .bytes = bytes, .previous_retained = true };
    return .{ .bytes = bytes };
}

fn exists(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    _ = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    return true;
}

fn valid_destination(io: std.Io, dir: std.Io.Dir, path: []const u8) !bool {
    const stat = dir.statFile(io, path, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    if (stat.kind != .file) return error.InvalidDestination;
    return true;
}

const NativeOperations = struct {
    io: std.Io,

    fn rename(self: @This(), dir: std.Io.Dir, from: []const u8, to: []const u8) !void {
        try dir.rename(from, dir, to, self.io);
    }

    fn delete_previous(self: @This(), dir: std.Io.Dir, path: []const u8) !void {
        try dir.deleteFile(self.io, path);
    }
};

pub fn write_bytes(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8, opts: ReplaceOptions) !ReplaceResult {
    const Body = struct {
        bytes: []const u8,
        fn write(self: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll(self.bytes);
        }
    };
    return write_replace(io, dir, path, Body{ .bytes = bytes }, opts);
}

/// Caller owns the returned Parsed value and must deinit it. Schema defaults,
/// migrations and range validation stay in the application.
pub fn load_json(comptime T: type, allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8, max_bytes: usize) !std.json.Parsed(T) {
    const bytes = try dir.readFileAlloc(io, path, allocator, .limited(max_bytes));
    defer allocator.free(bytes);

    return std.json.parseFromSlice(T, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = true });
}

/// The caller's buffer bounds serialization before any file is created.
pub fn save_json(io: std.Io, dir: std.Io.Dir, path: []const u8, value: anytype, buffer: []u8, opts: ReplaceOptions) !ReplaceResult {
    var writer = std.Io.Writer.fixed(buffer);
    try std.json.Stringify.value(value, .{ .whitespace = .indent_2 }, &writer);
    return write_bytes(io, dir, path, writer.buffered(), opts);
}

test "replacement preserves old contents on serialization failure and refuses stale files" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try write_bytes(io, tmp.dir, "settings", "old", .{});
    const Failing = struct {
        fn write(_: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("partial");
            return error.ForcedFailure;
        }
    };
    try std.testing.expectError(error.ForcedFailure, write_replace(io, tmp.dir, "settings", Failing{}, .{}));
    var bytes: [32]u8 = undefined;
    try std.testing.expectEqualStrings("old", try tmp.dir.readFile(io, "settings", &bytes));
    const stale = try tmp.dir.createFile(io, "settings.aether-tmp", .{});
    stale.close(io);
    try std.testing.expectError(error.PathAlreadyExists, write_bytes(io, tmp.dir, "settings", "new", .{}));
    try std.testing.expectEqualStrings("old", try tmp.dir.readFile(io, "settings", &bytes));
}

test "backup replacement and bounded JSON roundtrip" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    _ = try write_bytes(io, tmp.dir, "settings", "old", .{});
    const result = try write_bytes(io, tmp.dir, "settings", "new", .{ .strategy = .backup });
    try std.testing.expect(!result.previous_retained);
    try std.testing.expect(!try exists(io, tmp.dir, "settings.aether-previous"));
    const Settings = struct { name: []const u8, volume: u8 = 5 };
    var buffer: [128]u8 = undefined;
    _ = try save_json(io, tmp.dir, "prefs.json", Settings{ .name = "example" }, &buffer, .{});
    const parsed = try load_json(Settings, std.testing.allocator, io, tmp.dir, "prefs.json", 128);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("example", parsed.value.name);
    try std.testing.expectEqual(@as(u8, 5), parsed.value.volume);
    try std.testing.expectError(error.StreamTooLong, load_json(Settings, std.testing.allocator, io, tmp.dir, "prefs.json", 2));
}

test "replacement rejects directories and symlinks without moving them" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDir(io, "directory", .default_dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "directory/child", .data = "preserved" });
    inline for (.{ .replace, .backup }) |strategy| {
        try t.expectError(error.InvalidDestination, write_bytes(io, tmp.dir, "directory", "new", .{ .strategy = strategy }));
        try expect_file(io, tmp.dir, "directory/child", "preserved");
        try t.expect(!try exists(io, tmp.dir, "directory.aether-previous"));
        try t.expect(!try exists(io, tmp.dir, "directory.aether-tmp"));
    }
    // Some hosts cannot create symlinks without additional OS privileges.
    tmp.dir.symLink(io, "absent", "link", .{}) catch |err| switch (err) {
        error.AccessDenied, error.PermissionDenied => return error.SkipZigTest,
        else => return err,
    };
    inline for (.{ .replace, .backup }) |strategy| {
        try t.expectError(error.InvalidDestination, write_bytes(io, tmp.dir, "link", "new", .{ .strategy = strategy }));
        try t.expectEqual(std.Io.File.Kind.sym_link, (try tmp.dir.statFile(io, "link", .{ .follow_symlinks = false })).kind);
        try t.expect(!try exists(io, tmp.dir, "link.aether-tmp"));
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "settings", .data = "old" });
    try tmp.dir.symLink(io, "absent", "settings.aether-previous", .{});
    try t.expectError(error.BackupExists, write_bytes(io, tmp.dir, "settings", "new", .{ .strategy = .backup }));
    try expect_file(io, tmp.dir, "settings", "old");
    try t.expectEqual(std.Io.File.Kind.sym_link, (try tmp.dir.statFile(io, "settings.aether-previous", .{ .follow_symlinks = false })).kind);
    try t.expect(!try exists(io, tmp.dir, "settings.aether-tmp"));
}

const FaultOperations = struct {
    io: std.Io,
    fail_rename: [3]bool = @splat(false),
    rename_count: usize = 0,
    fail_cleanup: bool = false,

    fn rename(self: *@This(), dir: std.Io.Dir, from: []const u8, to: []const u8) !void {
        const step = self.rename_count;
        self.rename_count += 1;
        if (step < self.fail_rename.len and self.fail_rename[step]) return switch (step) {
            0 => error.AccessDenied,
            1 => error.NoSpaceLeft,
            else => error.ReadOnlyFileSystem,
        };
        try dir.rename(from, dir, to, self.io);
    }

    fn delete_previous(self: *@This(), dir: std.Io.Dir, path: []const u8) !void {
        if (self.fail_cleanup) return error.AccessDenied;
        try dir.deleteFile(self.io, path);
    }
};

fn expect_file(io: std.Io, dir: std.Io.Dir, path: []const u8, expected: ?[]const u8) !void {
    var buffer: [32]u8 = undefined;
    if (expected) |contents| {
        try std.testing.expectEqualStrings(contents, try dir.readFile(io, path, &buffer));
    } else {
        try std.testing.expect(!try exists(io, dir, path));
    }
}

test "promotion failures restore old data and failed rollback preserves recovery files" {
    const t = std.testing;
    const Body = struct {
        fn write(_: @This(), writer: *std.Io.Writer) !void {
            try writer.writeAll("new");
        }
    };
    const Failure = enum { initial_rename, promotion, rollback, cleanup, direct };
    inline for (std.meta.tags(Failure)) |failure| {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();

        try tmp.dir.writeFile(t.io, .{ .sub_path = "settings", .data = "old" });
        var operations: FaultOperations = .{ .io = t.io };
        switch (failure) {
            .initial_rename, .direct => operations.fail_rename[0] = true,
            .promotion => operations.fail_rename[1] = true,
            .rollback => operations.fail_rename = .{ false, true, true },
            .cleanup => operations.fail_cleanup = true,
        }
        const result = write_replace_using(t.io, tmp.dir, "settings", Body{}, .{
            .strategy = if (failure == .direct) .replace else .backup,
        }, &operations);
        switch (failure) {
            .initial_rename, .direct => try t.expectError(error.AccessDenied, result),
            .promotion => try t.expectError(error.NoSpaceLeft, result),
            .rollback => try t.expectError(error.RollbackFailed, result),
            .cleanup => {
                try t.expect((try result).previous_retained);
                try t.expectEqual(@as(u64, 3), (try result).bytes);
            },
        }
        if (failure == .rollback) {
            try expect_file(t.io, tmp.dir, "settings", null);
            try expect_file(t.io, tmp.dir, "settings.aether-previous", "old");
            try expect_file(t.io, tmp.dir, "settings.aether-tmp", "new");
        } else if (failure == .cleanup) {
            try expect_file(t.io, tmp.dir, "settings", "new");
            try expect_file(t.io, tmp.dir, "settings.aether-previous", "old");
            try expect_file(t.io, tmp.dir, "settings.aether-tmp", null);
        } else {
            try expect_file(t.io, tmp.dir, "settings", "old");
            try expect_file(t.io, tmp.dir, "settings.aether-previous", null);
            try expect_file(t.io, tmp.dir, "settings.aether-tmp", null);
        }
    }
}
