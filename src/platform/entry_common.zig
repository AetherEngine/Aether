const std = @import("std");
const aether = @import("aether");
const app_root = @import("aether_user_root");

pub const options: aether.Options = if (@hasDecl(app_root, "aether_options"))
    app_root.aether_options
else
    .{};

comptime {
    validate_user_root();
}

fn validate_user_root() void {
    if (!@hasDecl(app_root, "main")) {
        @compileError("Aether apps must expose pub fn main(init: std.process.Init) !void");
    }

    inline for (stale_root_decls) |decl| {
        if (@hasDecl(app_root, decl)) {
            @compileError("Aether root declaration '" ++ decl ++ "' is no longer supported; move entry configuration into pub const aether_options: aether.Options");
        }
    }

    const main_info = @typeInfo(@TypeOf(app_root.main)).@"fn";
    if (main_info.params.len != 1) {
        @compileError("Aether apps must expose main(std.process.Init); alternate main signatures are no longer supported");
    }

    const Param = main_info.params[0].type orelse
        @compileError("Aether app main parameter must have a concrete type");
    if (Param != std.process.Init) {
        @compileError("Aether app main parameter must be std.process.Init");
    }
}

const stale_root_decls = .{
    "std_options",
    "std_options_debug_threaded_io",
    "std_options_debug_io",
    "std_options_cwd",
    "panic",
    "zitrus_options",
    "psp_stack_size",
    "psp_async_stack_size",
    "psp_heap_kb_size",
    "psp_heap_reserve_kb_size",
};

pub fn call_main(init: std.process.Init) !void {
    return finish_main(app_root.main(init));
}

fn finish_main(result: anytype) !void {
    const Result = @TypeOf(result);
    switch (@typeInfo(Result)) {
        .void => return,
        .error_union => {
            const payload = try result;
            if (@TypeOf(payload) != void) {
                @compileError("Aether app main error union payload must be void");
            }
            return;
        },
        else => @compileError("Aether app main must return void or !void"),
    }
}
