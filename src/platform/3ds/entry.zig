//! 3DS entry shim.
//!
//! Zitrus owns the real process entry on 3DS, but Aether keeps that detail
//! inside the platform layer. User roots can keep accepting `std.process.Init`
//! like they do on other Aether targets.

const std = @import("std");
const aether = @import("aether");
const app_root = @import("aether_user_root");
const zitrus = @import("zitrus");

const Application = zitrus.horizon.Init.Application;

pub const std_options = if (@hasDecl(app_root, "std_options")) app_root.std_options else aether.Util.std_options;
pub const std_os_options = zitrus.std_os_options;
pub const panic = std.debug.FullPanic(zitrus.horizon.debug.defaultPanic);
pub const debug = @import("debug.zig");
pub const std_options_debug_threaded_io = null;
pub const std_options_debug_io: std.Io = zitrus.horizon.Io.debug_io;
pub const std_options_cwd = zitrus.horizon.Io.Dir.cwd;

pub fn main(init: Application) !void {
    debug.installExceptionHandler();

    aether.N3ds.setApplication(&init);
    defer aether.N3ds.clearApplication(&init);

    try zitrus.horizon.Io.global.initStorage(init.srv, .fs, 0);
    defer zitrus.horizon.Io.global.deinitFilesystem();

    zitrus.horizon.Io.global.mountSelfRomFs("romfs") catch {};
    zitrus.horizon.Io.global.mountArchive("sdmc", .sdmc, .empty, &.{}) catch {};

    var arena = std.heap.ArenaAllocator.init(init.base.gpa);
    defer arena.deinit();

    var environ_map = std.process.Environ.Map.init(init.base.gpa);
    defer environ_map.deinit();

    const process_init: std.process.Init = .{
        .minimal = .{
            .environ = .empty,
            .args = if (std.process.Args.Vector == void)
                .{ .vector = {} }
            else
                .{ .vector = &.{} },
        },
        .arena = &arena,
        .gpa = init.base.gpa,
        .io = init.base.io,
        .environ_map = &environ_map,
        .preopens = .empty,
    };

    try callUserMain(init, process_init);
}

fn callUserMain(app_init: Application, process_init: std.process.Init) !void {
    const main_fn = app_root.main;
    const info = @typeInfo(@TypeOf(main_fn)).@"fn";
    if (info.params.len == 0) {
        return finishMain(main_fn());
    }
    if (info.params.len != 1) {
        @compileError("3DS Aether apps must expose main(), main(std.process.Init), main(std.process.Init.Minimal), or main(zitrus.horizon.Init.Application)");
    }

    const Param = info.params[0].type orelse @compileError("3DS Aether app main parameter must have a concrete type");
    if (Param == std.process.Init) {
        return finishMain(main_fn(process_init));
    }
    if (Param == std.process.Init.Minimal) {
        return finishMain(main_fn(process_init.minimal));
    }
    if (Param == Application) {
        return finishMain(main_fn(app_init));
    }

    @compileError("unsupported 3DS Aether app main parameter type");
}

fn finishMain(result: anytype) !void {
    const Result = @TypeOf(result);
    switch (@typeInfo(Result)) {
        .void => return,
        .noreturn => unreachable,
        .error_union => {
            const payload = try result;
            return finishMain(payload);
        },
        .int, .comptime_int => {
            if (result != 0) return error.AetherMainReturnedFailure;
        },
        else => @compileError("unsupported 3DS Aether app main return type"),
    }
}
