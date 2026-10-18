const std = @import("std");
const Source = @import("source.zig").Source;

/// A bounded set of decoded assets. Retained names keep their T address across
/// successful apply/reload. Pointers are borrowed until that name is removed or
/// the store is destroyed. T must be movable (no pointers into its own value).
/// All reads/changes are caller-synchronized. Source ownership remains external.
pub fn AssetStoreType(comptime T: type) type {
    return struct {
        const Store = @This();
        const Entry = struct { path: []u8, value: T };
        pub const Loader = struct {
            context: ?*anyopaque = null,
            /// Must return a fully owned value; the reader closes on return.
            load: *const fn (?*anyopaque, std.mem.Allocator, []const u8, *std.Io.Reader) anyerror!T,
            destroy: *const fn (?*anyopaque, std.mem.Allocator, *T) void,
        };
        pub const ApplyOptions = struct {
            /// False retains already active names without reopening/decoding.
            reload_existing: bool = true,
        };

        allocator: std.mem.Allocator,
        loader: Loader,
        max_assets: usize,
        entries: std.ArrayList(*Entry) = .empty,

        pub fn init(allocator: std.mem.Allocator, loader: Loader, max_assets: usize) Store {
            return .{ .allocator = allocator, .loader = loader, .max_assets = max_assets };
        }

        pub fn deinit(self: *Store) void {
            for (self.entries.items) |entry| self.destroy_entry(entry);
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn get(self: *Store, path: []const u8) ?*T {
            const entry = self.find(path) orelse return null;
            return &entry.value;
        }

        pub fn count(self: *const Store) usize {
            return self.entries.items.len;
        }

        /// Loads every requested name from source before committing any change.
        /// Any open/load/allocation error leaves the complete active set usable.
        /// Success replaces retained values and drops names absent from paths.
        /// Repeating the active names implements a staged reload from a new source.
        pub fn apply(self: *Store, source: Source, paths: []const []const u8) !void {
            return self.apply_options(source, paths, .{});
        }

        /// Selects a new set while optionally keeping retained values. Reuse is
        /// appropriate when changing resident sets within the same asset source;
        /// reload_existing must remain true when replacing the source contents.
        pub fn apply_options(self: *Store, source: Source, paths: []const []const u8, options: ApplyOptions) !void {
            if (paths.len > self.max_assets) return error.TooManyAssets;
            for (paths, 0..) |path, i| {
                for (paths[0..i]) |previous| {
                    if (std.mem.eql(u8, path, previous)) return error.DuplicateAsset;
                }
            }
            var staged: std.ArrayList(*Entry) = .empty;
            defer staged.deinit(self.allocator);
            errdefer for (staged.items) |entry| {
                if (self.find(entry.path) != entry) self.destroy_entry(entry);
            };
            try staged.ensureTotalCapacity(self.allocator, paths.len);
            for (paths) |path| {
                if (!options.reload_existing) {
                    if (self.find(path)) |existing| {
                        staged.appendAssumeCapacity(existing);
                        continue;
                    }
                }
                const entry = try self.allocator.create(Entry);
                errdefer self.allocator.destroy(entry);
                const name = try self.allocator.dupe(u8, path);
                errdefer self.allocator.free(name);
                var reader = try source.open(path);
                defer reader.close();

                entry.* = .{ .path = name, .value = try self.loader.load(self.loader.context, self.allocator, path, reader.reader) };
                staged.appendAssumeCapacity(entry);
            }

            // All fallible operations are complete. Swap values into retained
            // allocations, then destroy their old values with obsolete entries.
            for (staged.items) |*replacement| {
                if (self.find(replacement.*.path)) |existing| {
                    if (replacement.* == existing) continue;
                    std.mem.swap(T, &existing.value, &replacement.*.value);
                    for (self.entries.items) |*active| {
                        if (active.* == existing) {
                            active.* = replacement.*;
                            replacement.* = existing;
                            break;
                        }
                    }
                }
            }
            for (self.entries.items) |entry| {
                if (std.mem.indexOfScalar(*Entry, staged.items, entry) == null) self.destroy_entry(entry);
            }
            self.entries.deinit(self.allocator);
            self.entries = staged;
            staged = .empty;
        }

        fn find(self: *const Store, path: []const u8) ?*Entry {
            for (self.entries.items) |entry| {
                if (std.mem.eql(u8, entry.path, path)) return entry;
            }
            return null;
        }

        fn destroy_entry(self: *Store, entry: *Entry) void {
            self.loader.destroy(self.loader.context, self.allocator, &entry.value);
            self.allocator.free(entry.path);
            self.allocator.destroy(entry);
        }
    };
}
