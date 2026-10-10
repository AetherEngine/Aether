//! Browser services exposed to applications as `aether.Web`.

extern "aether_host" fn aether_download_file(
    path: [*]const u8,
    path_len: usize,
    filename: [*]const u8,
    filename_len: usize,
    content_type: [*]const u8,
    content_type_len: usize,
) bool;

pub const FileExport = struct {
    pub const Error = error{ InvalidOptions, ExportFailed };
    pub const Options = struct {
        filename: []const u8,
        content_type: []const u8 = "application/octet-stream",
    };

    /// Initiates a browser download of a virtual file. Success does not imply
    /// the user saved it.
    pub fn download(path: []const u8, opts: Options) Error!void {
        if (path.len == 0 or opts.filename.len == 0 or opts.content_type.len == 0) return error.InvalidOptions;
        const started = aether_download_file(
            path.ptr,
            path.len,
            opts.filename.ptr,
            opts.filename.len,
            opts.content_type.ptr,
            opts.content_type.len,
        );
        if (!started) return error.ExportFailed;
    }
};
