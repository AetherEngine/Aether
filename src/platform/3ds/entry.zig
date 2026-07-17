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
const horizon = zitrus.horizon;
const MIN_STACK_SIZE: u32 = 768 * 1024;
const SOC_BUFFER_LEN: usize = 1024 * 1024;
const log = std.log.scoped(.aether_3ds_entry);

pub const zitrus_options = if (@hasDecl(app_root, "zitrus_options"))
    .{ .stack_size = @max(MIN_STACK_SIZE, app_root.zitrus_options.stack_size) }
else
    .{ .stack_size = MIN_STACK_SIZE };

pub const std_options = if (@hasDecl(app_root, "std_options")) app_root.std_options else aether.Util.std_options;
pub const std_os_options = zitrus.std_os_options;
pub const panic = std.debug.FullPanic(zitrus.horizon.debug.defaultPanic);
pub const std_options_debug_threaded_io = null;
pub const std_options_debug_io: std.Io = zitrus.horizon.Io.debug_io;
pub const std_options_cwd = zitrus.horizon.Io.Dir.cwd;

pub fn main(init: Application) !void {
    aether.N3ds.setApplication(init);
    defer aether.N3ds.clearApplication();

    try zitrus.horizon.Io.global.initStorage(init.srv, .fs, 0);
    defer zitrus.horizon.Io.global.deinitFilesystem();

    var network = NetworkContext.init(init.srv, init.base.gpa) catch |err| blk: {
        log.warn("3DS network init skipped: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (network) |*ctx| ctx.deinit();

    zitrus.horizon.Io.global.mountSelfRomFs("romfs") catch {};
    zitrus.horizon.Io.global.mountArchive("sdmc", .sdmc, .empty, &.{}) catch {};

    const linear_gpa = zitrus.horizon.heap.linear_page_allocator;

    var arena = std.heap.ArenaAllocator.init(linear_gpa);
    defer arena.deinit();

    var environ_map = std.process.Environ.Map.init(linear_gpa);
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
        .gpa = linear_gpa,
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

const NetworkContext = struct {
    soc: horizon.services.SocketUser,
    memory: horizon.MemoryBlock,
    buffer: []align(horizon.heap.page_size) u8,
    alloc: std.mem.Allocator,

    fn init(srv: horizon.ServiceManager, alloc: std.mem.Allocator) !NetworkContext {
        const soc = try horizon.services.SocketUser.open(srv);
        errdefer soc.close();

        const buffer = try alloc.alignedAlloc(u8, .fromByteUnits(horizon.heap.page_size), SOC_BUFFER_LEN);
        errdefer alloc.free(buffer);

        const memory: horizon.MemoryBlock = try .create(buffer.ptr, buffer.len, .none, .rw);
        errdefer memory.close();

        try soc.sendInitialize(memory, buffer.len);
        errdefer soc.sendDeinitialize();

        try horizon.Io.global.initNetwork(.{ .soc = soc, .extra = .unowned });

        return .{
            .soc = soc,
            .memory = memory,
            .buffer = buffer,
            .alloc = alloc,
        };
    }

    fn deinit(self: *NetworkContext) void {
        horizon.Io.global.deinitNetwork();
        self.soc.sendDeinitialize();
        self.memory.close();
        self.alloc.free(self.buffer);
        self.soc.close();
    }
};
