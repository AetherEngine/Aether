const options = @import("options");
pub const Error = error{ UnsupportedPlatform, InvalidOptions, ExportFailed };
pub const Options = struct {
    filename: []const u8,
    content_type: []const u8 = "application/octet-stream",
};

/// Initiates a browser download of a virtual file. Success does not imply the
/// user saved it. Other platforms explicitly return UnsupportedPlatform.
pub fn download(path: []const u8, opts: Options) Error!void {
    if (options.config.platform != .wasm) return error.UnsupportedPlatform;
    if (path.len == 0 or opts.filename.len == 0 or opts.content_type.len == 0) return error.InvalidOptions;
    if (!@import("wasm/file_export.zig").download(path, opts.filename, opts.content_type)) return error.ExportFailed;
}
