const options = @import("options");

pub const c = @cImport({
    @cUndef("_GNU_SOURCE");
    @cUndef("_DEFAULT_SOURCE");
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("wint_t", "__WINT_TYPE__");

    switch (options.config.platform) {
        .nintendo_3ds => {
            @cDefine("__3DS__", "1");
            @cDefine("ARM11", "1");
        },
        .nintendo_switch => {
            @cDefine("__SWITCH__", "1");
        },
        else => @compileError("platform/nintendo_c.zig is only wired for Nintendo targets"),
    }

    @cInclude("errno.h");
    @cInclude("fcntl.h");
    @cInclude("dirent.h");
    @cInclude("sys/iosupport.h");
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
    @cInclude("malloc.h");
    @cInclude("stdio.h");

    switch (options.config.platform) {
        .nintendo_3ds => {
            @cInclude("3ds/types.h");
            @cInclude("3ds/thread.h");
            @cInclude("3ds/allocator/linear.h");
            @cInclude("3ds/archive.h");
            @cInclude("3ds/romfs.h");
            @cInclude("3ds/svc.h");
        },
        .nintendo_switch => {
            @cInclude("switch/aether_switch_import.h");
        },
        else => unreachable,
    }
});
