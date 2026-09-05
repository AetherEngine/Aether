//! Asset sources and staged ownership. Source readers and store values have
//! separate lifetimes; stores close each reader after the loader returns.
pub const Source = @import("source.zig").Source;
pub const Reader = @import("source.zig").Reader;
pub const MemorySource = @import("source.zig").MemorySource;
pub const DirectorySource = @import("source.zig").DirectorySource;
pub const AssetStore = @import("store.zig").AssetStoreType;

test {
    @import("std").testing.refAllDecls(@This());
}
