//! Indexed, read-only ZIP entries. Archive and reader addresses are stable on
//! the heap. Supports stored and raw DEFLATE entries, never extracts to disk.
//! The archive file must remain unchanged until deinit.
const Zip = @This();
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const zip = std.zip;
const resources = @import("../resources/source.zig");

pub const Options = struct {
    max_streams: usize = 2,
    /// Independent DEFLATE windows; null permits every stream to decompress.
    /// Stored entries do not reserve a window.
    max_deflate_streams: ?usize = null,
    max_entries: usize = 65536,
    max_filename_bytes: usize = 1024,
    max_total_filename_bytes: usize = 8 * 1024 * 1024,
    max_entry_bytes: u64 = 256 * 1024 * 1024,
};

allocator: std.mem.Allocator,
file: Io.File,
io: Io,
options: Options,
file_size: u64,
data_end: u64,
index: []IndexEntry,
names: []u8,
slots: []Slot,
windows: []Window,

const IndexEntry = struct { entry: zip.Iterator.Entry, name_offset: usize };
const Window = struct {
    bytes: [std.compress.flate.max_window_len]u8 = undefined,
    input_buffer: [4096]u8 = undefined,
    decompressor: std.compress.flate.Decompress = undefined,
    in_use: bool = false,
};

const Slot = struct {
    in_use: bool = false,
    generation: u64 = 0,
    file_buffer: [4096]u8 = undefined,
    file_reader: Io.File.Reader = undefined,
    compressed: Io.Reader.Limited = undefined,
    window: ?*Window = null,
    input: *Io.Reader = undefined,
    output_buffer: [4096]u8 = undefined,
    reader: Io.Reader = undefined,
    remaining: u64 = 0,
    crc: std.hash.Crc32 = .init(),
    expected_crc: u32 = 0,
    failure: ?error{ InvalidCrc, InvalidSize, ReadFailed } = null,

    fn read(r: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const self: *Slot = @alignCast(@fieldParentPtr("reader", r));
        if (self.failure != null) return error.ReadFailed;
        if (self.remaining == 0) return error.EndOfStream;
        var scratch: [4096]u8 = undefined;
        const size: usize = @intCast(@min(self.remaining, limit.minInt(scratch.len)));
        if (size == 0) return 0;
        const count = self.input.readSliceShort(scratch[0..size]) catch {
            self.failure = error.ReadFailed;
            return error.ReadFailed;
        };
        if (count != size) {
            self.failure = error.InvalidSize;
            return error.ReadFailed;
        }
        self.crc.update(scratch[0..count]);
        self.remaining -= count;
        if (self.remaining == 0) {
            var extra: [1]u8 = undefined;
            const tail = self.input.readSliceShort(&extra) catch {
                self.failure = error.ReadFailed;
                return error.ReadFailed;
            };
            if (tail != 0) {
                self.failure = error.InvalidSize;
                return error.ReadFailed;
            }
            if (self.crc.final() != self.expected_crc) {
                self.failure = error.InvalidCrc;
                return error.ReadFailed;
            }
        }
        try writer.writeAll(scratch[0..count]);
        return count;
    }

    fn close(context: ?*anyopaque) void {
        const self: *Slot = @ptrCast(@alignCast(context.?));
        assert(self.in_use);
        if (self.window) |window| {
            window.in_use = false;
            self.window = null;
        }
        self.in_use = false;
    }
};

/// Borrowed reader and metadata. Close through close_stream exactly once;
/// do not copy a live stream. A full read verifies length and CRC, while closing
/// a partially read entry intentionally does not drain or authenticate it.
pub const Stream = struct {
    slot_index: usize,
    generation: u64,
    reader: *Io.Reader,
    data_offset: u64,
    byte_length: u64,
    compression_method: zip.CompressionMethod,
};

pub fn init(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8) !*Zip {
    return init_options(allocator, io, dir, path, .{});
}

pub fn init_options(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, path: []const u8, options: Options) !*Zip {
    if (options.max_streams == 0) return error.InvalidOptions;
    const self = try allocator.create(Zip);
    errdefer allocator.destroy(self);
    const file = try dir.openFile(io, path, .{});
    errdefer file.close(io);
    const slots = try allocator.alloc(Slot, options.max_streams);
    errdefer allocator.free(slots);
    const windows = try allocator.alloc(Window, @min(options.max_deflate_streams orelse options.max_streams, options.max_streams));
    errdefer allocator.free(windows);
    for (slots) |*slot| slot.* = .{};
    for (windows) |*window| window.* = .{};
    self.* = .{ .allocator = allocator, .file = file, .io = io, .options = options, .slots = slots, .windows = windows, .file_size = undefined, .data_end = undefined, .index = undefined, .names = undefined };
    try self.build_index();
    return self;
}

/// All streams must have closed before archive destruction.
pub fn deinit(self: *Zip) void {
    for (self.slots) |slot| assert(!slot.in_use);
    self.allocator.free(self.index);
    self.allocator.free(self.names);
    self.allocator.free(self.slots);
    self.allocator.free(self.windows);
    self.file.close(self.io);
    const allocator = self.allocator;
    self.* = undefined;
    allocator.destroy(self);
}

fn build_index(self: *Zip) !void {
    var reader = Io.File.Reader.init(self.file, self.io, &self.slots[0].file_buffer);
    self.file_size = try reader.getSize();
    var iter = try zip.Iterator.init(&reader);
    if (iter.cd_record_count > self.options.max_entries) return error.ZipTooManyEntries;
    if (iter.cd_zip_offset > self.file_size or iter.cd_size > self.file_size - iter.cd_zip_offset) return error.ZipBadCdOffset;
    self.data_end = iter.cd_zip_offset;
    var name_bytes: usize = 0;
    while (try iter.next()) |entry| {
        if (entry.filename_len > self.options.max_filename_bytes) return error.ZipFilenameTooLong;
        if (entry.filename_len > self.options.max_total_filename_bytes - name_bytes) return error.ZipNamesTooLarge;
        if (entry.uncompressed_size > self.options.max_entry_bytes) return error.ZipEntryTooLarge;
        name_bytes += entry.filename_len;
    }
    const index = try self.allocator.alloc(IndexEntry, @intCast(iter.cd_record_count));
    errdefer self.allocator.free(index);
    const names = try self.allocator.alloc(u8, name_bytes);
    errdefer self.allocator.free(names);
    iter = try zip.Iterator.init(&reader);
    var i: usize = 0;
    var offset: usize = 0;
    while (try iter.next()) |entry| {
        if (i >= index.len or entry.filename_len > names.len - offset) return error.ZipChanged;
        const name = names[offset..][0..entry.filename_len];
        try reader.seekTo(entry.header_zip_offset + @sizeOf(zip.CentralDirectoryFileHeader));
        try reader.interface.readSliceAll(name);
        index[i] = .{ .entry = entry, .name_offset = offset };
        offset += name.len;
        i += 1;
    }
    if (i != index.len or offset != names.len) return error.ZipChanged;
    std.mem.sort(IndexEntry, index, @as([]const u8, names), struct {
        fn less_than(blob: []const u8, a: IndexEntry, b: IndexEntry) bool {
            return std.mem.lessThan(u8, blob[a.name_offset..][0..a.entry.filename_len], blob[b.name_offset..][0..b.entry.filename_len]);
        }
    }.less_than);
    if (index.len > 1) for (index[1..], index[0 .. index.len - 1]) |entry, previous| {
        if (std.mem.eql(u8, names[entry.name_offset..][0..entry.entry.filename_len], names[previous.name_offset..][0..previous.entry.filename_len])) return error.ZipDuplicateEntry;
    };
    self.index = index;
    self.names = names;
}

pub fn contains(self: *const Zip, path: []const u8) bool {
    return self.find(path) != null;
}

fn find(self: *const Zip, path: []const u8) ?*const zip.Iterator.Entry {
    var low: usize = 0;
    var high = self.index.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const indexed = &self.index[mid];
        switch (std.mem.order(u8, path, self.names[indexed.name_offset..][0..indexed.entry.filename_len])) {
            .eq => return &indexed.entry,
            .lt => high = mid,
            .gt => low = mid + 1,
        }
    }
    return null;
}

pub fn open(self: *Zip, path: []const u8) !Stream {
    const entry = self.find(path) orelse return error.FileNotFound;
    const slot_index = for (self.slots, 0..) |slot, i| {
        if (!slot.in_use) break i;
    } else return error.StreamsExhausted;
    const slot = &self.slots[slot_index];
    assert(slot.window == null);
    errdefer if (slot.window) |window| {
        window.in_use = false;
        slot.window = null;
    };
    if (entry.file_offset > self.data_end or @sizeOf(zip.LocalFileHeader) > self.data_end - entry.file_offset) return error.ZipBadFileOffset;
    slot.file_reader = .init(self.file, self.io, &slot.file_buffer);
    try slot.file_reader.seekTo(entry.file_offset);
    const header = try slot.file_reader.interface.takeStruct(zip.LocalFileHeader, .little);
    if (!std.mem.eql(u8, &header.signature, &zip.local_file_header_sig)) return error.ZipBadFileOffset;
    if (header.flags.encrypted) return error.ZipEncryptionUnsupported;
    if (header.compression_method != entry.compression_method or header.filename_len != entry.filename_len) return error.ZipHeaderMismatch;
    // Read the local name in chunks, avoiding a filename-sized stack allocation.
    var compared: usize = 0;
    var name_buffer: [256]u8 = undefined;
    while (compared < path.len) {
        const n = @min(path.len - compared, name_buffer.len);
        try slot.file_reader.interface.readSliceAll(name_buffer[0..n]);
        if (!std.mem.eql(u8, name_buffer[0..n], path[compared..][0..n])) return error.ZipHeaderMismatch;
        compared += n;
    }
    const data_offset = std.math.add(u64, entry.file_offset, @sizeOf(zip.LocalFileHeader) + @as(u64, header.filename_len) + header.extra_len) catch return error.ZipBadFileOffset;
    if (data_offset > self.data_end or entry.compressed_size > self.data_end - data_offset) return error.ZipBadFileOffset;
    try slot.file_reader.seekTo(data_offset);
    slot.compressed = .init(&slot.file_reader.interface, .limited64(entry.compressed_size), &.{});
    slot.input = switch (entry.compression_method) {
        .store => blk: {
            if (entry.compressed_size != entry.uncompressed_size) return error.ZipHeaderMismatch;
            break :blk &slot.compressed.interface;
        },
        .deflate => blk: {
            const window = for (self.windows) |*candidate| {
                if (!candidate.in_use) break candidate;
            } else return error.DeflateStreamsExhausted;
            window.in_use = true;
            slot.window = window;
            slot.compressed.interface.buffer = &window.input_buffer;
            window.decompressor = .init(&slot.compressed.interface, .raw, &window.bytes);
            break :blk &window.decompressor.reader;
        },
        else => return error.UnsupportedCompressionMethod,
    };
    slot.remaining = entry.uncompressed_size;
    slot.crc = .init();
    slot.expected_crc = entry.crc32;
    slot.failure = null;
    slot.reader = .{ .vtable = &.{ .stream = Slot.read }, .buffer = &slot.output_buffer, .seek = 0, .end = 0 };
    if (entry.uncompressed_size == 0) {
        var extra: [1]u8 = undefined;
        if (try slot.input.readSliceShort(&extra) != 0) return error.InvalidSize;
        if (entry.crc32 != slot.crc.final()) return error.InvalidCrc;
    }
    slot.in_use = true;
    slot.generation +%= 1;
    return .{ .slot_index = slot_index, .generation = slot.generation, .reader = &slot.reader, .data_offset = data_offset, .byte_length = entry.uncompressed_size, .compression_method = entry.compression_method };
}

pub fn close_stream(self: *Zip, stream: *const Stream) void {
    assert(stream.slot_index < self.slots.len);
    const slot = &self.slots[stream.slot_index];
    assert(slot.in_use and slot.generation == stream.generation);
    Slot.close(slot);
}

/// Detailed error after an entry reader reports ReadFailed.
pub fn stream_error(self: *Zip, stream: *const Stream) ?anyerror {
    const slot = &self.slots[stream.slot_index];
    assert(slot.in_use and slot.generation == stream.generation);
    return slot.failure;
}

pub fn source(self: *Zip) resources.Source {
    return .{ .context = self, .open_fn = open_source };
}

fn open_source(context: *anyopaque, path: []const u8) !resources.Reader {
    const self: *Zip = @ptrCast(@alignCast(context));
    const stream = try self.open(path);
    return .{ .reader = stream.reader, .context = &self.slots[stream.slot_index], .close_fn = Slot.close };
}

const fixture = @embedFile("testdata/resources.zip");

fn test_archive(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "resources.zip", .data = fixture });
    const archive = try init(allocator, std.testing.io, tmp.dir, "resources.zip");
    defer archive.deinit();

    const compressed = try archive.open("deflated.txt");
    defer archive.close_stream(&compressed);

    var buffer: ["Independent streaming reader. ".len]u8 = undefined;
    {
        const stored = try archive.open("stored.txt");
        defer archive.close_stream(&stored);

        try std.testing.expectError(error.StreamsExhausted, archive.open("nested/data"));
        try std.testing.expectEqualStrings("Aether", try stored.reader.take(6));
        for (0..200) |_| {
            try compressed.reader.readSliceAll(&buffer);
            try std.testing.expectEqualStrings("Independent streaming reader. ", &buffer);
        }
        try std.testing.expectEqualStrings(" resources", try stored.reader.take(10));
        try std.testing.expectError(error.EndOfStream, stored.reader.takeByte());
    }
    var nested = try archive.source().open("nested/data");
    defer nested.close();

    try std.testing.expectEqualStrings("nested", try nested.reader.take(6));
    for (0..200) |_| {
        try compressed.reader.readSliceAll(&buffer);
        try std.testing.expectEqualStrings("Independent streaming reader. ", &buffer);
    }
    try std.testing.expectError(error.EndOfStream, compressed.reader.takeByte());
    nested.close();
    var empty = try archive.source().open("empty");
    defer empty.close();

    try std.testing.expectError(error.EndOfStream, empty.reader.takeByte());
    try std.testing.expectError(error.FileNotFound, archive.open("missing"));
}

test "ZIP stored and deflated overlapping readers are bounded and reusable" {
    try test_archive(std.testing.allocator);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, test_archive, .{});
}

test "ZIP simultaneous readers cross input and output buffer boundaries" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(t.io, .{ .sub_path = "test.zip", .data = fixture });
    const archive = try init(t.allocator, t.io, tmp.dir, "test.zip");
    defer archive.deinit();

    var a = try archive.source().open("large-stored.bin");
    defer a.close();

    var b = try archive.source().open("large-deflated.bin");
    defer b.close();

    var offset: usize = 0;
    while (offset < 16384) {
        const size = @min(173, 16384 - offset);
        const stored = try a.reader.take(size);
        const deflated = try b.reader.take(size);
        try t.expectEqualSlices(u8, stored, deflated);
        for (stored, offset..) |byte, i| {
            const n: u64 = i;
            try t.expectEqual(@as(u8, @truncate(n * 37 + ((n * n) >> 8) + ((n * n * n) >> 17))), byte);
        }
        offset += size;
    }
    try t.expectError(error.EndOfStream, a.reader.takeByte());
    try t.expectError(error.EndOfStream, b.reader.takeByte());
}

test "ZIP stored readers do not reserve the bounded DEFLATE window pool" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(t.io, .{ .sub_path = "test.zip", .data = fixture });
    const archive = try init_options(t.allocator, t.io, tmp.dir, "test.zip", .{ .max_streams = 3, .max_deflate_streams = 1 });
    defer archive.deinit();

    var stored = try archive.source().open("stored.txt");
    defer stored.close();

    var compressed = try archive.source().open("deflated.txt");
    defer compressed.close();

    try t.expectError(error.DeflateStreamsExhausted, archive.open("large-deflated.bin"));
    var another_stored = try archive.source().open("nested/data");
    another_stored.close();
    compressed.close();
    var replacement = try archive.source().open("large-deflated.bin");
    defer replacement.close();

    try t.expectEqualStrings("Aether resources", try stored.reader.take(16));
    // Closing a partial DEFLATE read also returns its window to the pool.
    replacement.close();
    try t.expect(!archive.windows[0].in_use);
}

test "ZIP bounds, malformed data, CRC and configurable limits" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(t.io, .{ .sub_path = "test.zip", .data = fixture });
    try t.expectError(error.ZipTooManyEntries, init_options(t.allocator, t.io, tmp.dir, "test.zip", .{ .max_entries = 1 }));
    try t.expectError(error.ZipEntryTooLarge, init_options(t.allocator, t.io, tmp.dir, "test.zip", .{ .max_entry_bytes = 10 }));
    try t.expectError(error.ZipFilenameTooLong, init_options(t.allocator, t.io, tmp.dir, "test.zip", .{ .max_filename_bytes = 1 }));
    try t.expectError(error.InvalidOptions, init_options(t.allocator, t.io, tmp.dir, "test.zip", .{ .max_streams = 0 }));

    var corrupt: [fixture.len]u8 = fixture.*;
    // The first stored entry's payload starts after its local name.
    corrupt[@sizeOf(zip.LocalFileHeader) + "stored.txt".len] ^= 0xff;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "corrupt.zip", .data = &corrupt });
    const archive = try init(t.allocator, t.io, tmp.dir, "corrupt.zip");
    defer archive.deinit();

    const stream = try archive.open("stored.txt");
    defer archive.close_stream(&stream);

    try t.expectError(error.ReadFailed, stream.reader.takeByte());
    try t.expectEqual(error.InvalidCrc, archive.stream_error(&stream).?);

    corrupt = fixture.*;
    const deflate_data = std.mem.indexOf(u8, &corrupt, "deflated.txt").? + "deflated.txt".len;
    // A raw DEFLATE block type of 3 is reserved and must fail decoding.
    corrupt[deflate_data] = (corrupt[deflate_data] & 0xf8) | 7;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "deflate.zip", .data = &corrupt });
    const broken = try init(t.allocator, t.io, tmp.dir, "deflate.zip");
    defer broken.deinit();

    const broken_stream = try broken.open("deflated.txt");
    defer broken.close_stream(&broken_stream);

    try t.expectError(error.ReadFailed, broken_stream.reader.takeByte());

    corrupt = fixture.*;
    // An impossible local file offset must be rejected before seeking.
    const central = std.mem.indexOf(u8, &corrupt, &zip.central_file_header_sig).?;
    std.mem.writeInt(u32, corrupt[central + 42 ..][0..4], 0xfffffffe, .little);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "offset.zip", .data = &corrupt });
    const invalid = try init(t.allocator, t.io, tmp.dir, "offset.zip");
    defer invalid.deinit();

    try t.expectError(error.ZipBadFileOffset, invalid.open("stored.txt"));
}
