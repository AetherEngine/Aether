//! Sources are borrowed; each successful open transfers one independent reader.
const std = @import("std");

/// Move-only owner by convention. Do not copy an open Reader or use its reader
/// after close. Closing the same owning value twice is harmless. A source must
/// remain alive until all its readers have closed. Calls are not synchronized.
pub const Reader = struct {
    reader: *std.Io.Reader,
    context: ?*anyopaque,
    close_fn: *const fn (?*anyopaque) void,
    closed: bool = false,

    pub fn close(self: *Reader) void {
        if (self.closed) return;
        self.closed = true;
        self.close_fn(self.context);
    }
};

pub const Source = struct {
    context: *anyopaque,
    open_fn: *const fn (*anyopaque, []const u8) anyerror!Reader,

    pub fn open(self: Source, path: []const u8) !Reader {
        return self.open_fn(self.context, path);
    }
};

/// Borrows immutable file names and bytes, which must outlive open readers.
pub const MemorySource = struct {
    pub const File = struct { path: []const u8, bytes: []const u8 };
    allocator: std.mem.Allocator,
    files: []const File,

    const OpenFile = struct {
        allocator: std.mem.Allocator,
        reader: std.Io.Reader,

        fn close(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.allocator.destroy(self);
        }
    };

    pub fn source(self: *MemorySource) Source {
        return .{ .context = self, .open_fn = open };
    }

    fn open(context: *anyopaque, path: []const u8) !Reader {
        const self: *MemorySource = @ptrCast(@alignCast(context));
        const bytes = for (self.files) |file| {
            if (std.mem.eql(u8, file.path, path)) break file.bytes;
        } else return error.FileNotFound;
        const file = try self.allocator.create(OpenFile);
        file.* = .{ .allocator = self.allocator, .reader = .fixed(bytes) };
        return .{ .reader = &file.reader, .context = file, .close_fn = OpenFile.close };
    }
};

/// Borrows the directory handle and Io. Uses separate file handles and buffers
/// for overlapping reads. Resource paths are relative slash-separated names;
/// this validation is not a sandbox against symlinks inside the directory.
pub const DirectorySource = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,

    const OpenFile = struct {
        allocator: std.mem.Allocator,
        io: std.Io,
        file: std.Io.File,
        buffer: [4096]u8 = undefined,
        reader: std.Io.File.Reader,

        fn close(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.file.close(self.io);
            self.allocator.destroy(self);
        }
    };

    pub fn source(self: *DirectorySource) Source {
        return .{ .context = self, .open_fn = open };
    }

    fn open(context: *anyopaque, path: []const u8) !Reader {
        const self: *DirectorySource = @ptrCast(@alignCast(context));
        if (!valid_path(path)) return error.InvalidResourcePath;
        const file = try self.allocator.create(OpenFile);
        errdefer self.allocator.destroy(file);
        file.* = .{
            .allocator = self.allocator,
            .io = self.io,
            .file = try self.dir.openFile(self.io, path, .{}),
            .reader = undefined,
        };
        file.reader = file.file.readerStreaming(self.io, &file.buffer);
        return .{ .reader = &file.reader.interface, .context = file, .close_fn = OpenFile.close };
    }
};

pub fn valid_path(path: []const u8) bool {
    if (path.len == 0 or std.mem.indexOfAny(u8, path, "\\:\x00") != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

test "memory source readers have independent cursors and close once" {
    var source: MemorySource = .{ .allocator = std.testing.allocator, .files = &.{.{ .path = "a", .bytes = "abcdef" }} };
    var a = try source.source().open("a");
    defer a.close();

    var b = try source.source().open("a");
    defer b.close();

    try std.testing.expectEqualStrings("abc", try a.reader.take(3));
    try std.testing.expectEqualStrings("ab", try b.reader.take(2));
    try std.testing.expectEqualStrings("def", try a.reader.take(3));
    a.close();
    try std.testing.expectError(error.FileNotFound, source.source().open("missing"));
}

test "directory source validates names and supports independent readers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "asset", .data = "hello" });
    var source: DirectorySource = .{ .allocator = std.testing.allocator, .io = std.testing.io, .dir = tmp.dir };
    try std.testing.expectError(error.InvalidResourcePath, source.source().open("../asset"));
    try std.testing.expectError(error.InvalidResourcePath, source.source().open("/asset"));
    var a = try source.source().open("asset");
    defer a.close();

    var b = try source.source().open("asset");
    defer b.close();

    try std.testing.expectEqualStrings("hel", try a.reader.take(3));
    try std.testing.expectEqualStrings("hello", try b.reader.take(5));
    try std.testing.expectEqualStrings("lo", try a.reader.take(2));
}
