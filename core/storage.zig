//! Bounded settings I/O and replacement writes. Callers serialize writes to a
//! destination and reserve its .aether-tmp/.aether-previous sibling names.
const std = @import("std");
const platform_io = @import("platform").io;

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
    var temp_buf: [platform_io.max_path_bytes]u8 = undefined;
    var previous_buf: [platform_io.max_path_bytes]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buf, "{s}.aether-tmp", .{path});
    const previous = try std.fmt.bufPrint(&previous_buf, "{s}.aether-previous", .{path});
    const replace = switch (opts.strategy) {
        .platform_default => platform_io.rename_replaces_destination,
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
