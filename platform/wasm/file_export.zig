extern "aether_host" fn aether_download_file(path: [*]const u8, path_len: usize, filename: [*]const u8, filename_len: usize, content_type: [*]const u8, content_type_len: usize) bool;

pub fn download(path: []const u8, filename: []const u8, content_type: []const u8) bool {
    return aether_download_file(path.ptr, path.len, filename.ptr, filename.len, content_type.ptr, content_type.len);
}
