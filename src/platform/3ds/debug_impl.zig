//! 3DS exception reporting implementation.

const std = @import("std");
const zitrus = @import("zitrus");

const horizon = zitrus.horizon;
pub const Exception = horizon.ErrorDisplayManager.Exception;
pub const ExceptionHandler = *const fn (*const Exception.Info, *const Exception.Registers) callconv(.c) noreturn;

threadlocal var exception_stage: usize = 0;

pub fn installExceptionHandler(entry: ExceptionHandler) void {
    horizon.tls.get().exception = .{
        .stack = .inherit,
        .context = .store_inherited,
        .entry = entry,
    };

    zitrus.hardware.cpu.cache.dataSynchronizationBarrier();
    zitrus.hardware.cpu.cache.flushPrefetchBuffer();
}

pub fn installDefaultExceptionHandler() void {
    installExceptionHandler(&handleException);
}

pub fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: ?std.debug.CpuContextPtr) noreturn {
    @branchHint(.cold);

    defer while (true) horizon.breakExecution(.panic);

    switch (exception_stage) {
        0 => {
            exception_stage = 1;

            var user_buffer: [256]u8 = undefined;
            var user_writer: std.Io.Writer = .fixed(&user_buffer);
            writeGenericReport(&user_writer, name, addr, opt_ctx) catch {};

            zitrus.horizon.debug.print("{s}\n", .{user_writer.buffered()});

            var errdisp = horizon.ErrorDisplayManager.open() catch {
                zitrus.horizon.debug.print("exception: could not open err:f connection\n", .{});
                while (true) horizon.breakExecution(.panic);
            };
            defer errdisp.close();

            errdisp.sendSetUserString(user_writer.buffered()) catch zitrus.horizon.debug.print("exception: 'err:f' could not set user string", .{});
            errdisp.sendThrow(failureError(name, addr, opt_ctx)) catch zitrus.horizon.debug.print("exception: 'err:f' could not throw with message '{s}'", .{name});
        },
        1 => {
            exception_stage = 2;
            zitrus.horizon.debug.print("exception: recursive fault while reporting\n", .{});
        },
        else => {},
    }
}

pub fn handleException(info: *const Exception.Info, registers: *const Exception.Registers) callconv(.c) noreturn {
    @branchHint(.cold);

    defer while (true) horizon.breakExecution(.panic);

    switch (exception_stage) {
        0 => {
            exception_stage = 1;

            const name = exceptionName(info.*);

            var trace_buffer: [512]u8 = undefined;
            var trace_writer: std.Io.Writer = .fixed(&trace_buffer);
            writeExceptionReport(&trace_writer, name, info, registers) catch {};
            zitrus.horizon.debug.print("{s}\n", .{trace_writer.buffered()});

            var user_buffer: [256]u8 = undefined;
            var user_writer: std.Io.Writer = .fixed(&user_buffer);
            writeExceptionReport(&user_writer, name, info, registers) catch {};

            var errdisp = horizon.ErrorDisplayManager.open() catch {
                zitrus.horizon.debug.print("exception: could not open err:f connection\n", .{});
                while (true) horizon.breakExecution(.panic);
            };
            defer errdisp.close();

            errdisp.sendSetUserString(user_writer.buffered()) catch zitrus.horizon.debug.print("exception: 'err:f' could not set user string", .{});
            errdisp.sendThrow(exceptionError(info, registers)) catch zitrus.horizon.debug.print("exception: 'err:f' could not throw {s}", .{name});
        },
        1 => {
            exception_stage = 2;
            zitrus.horizon.debug.print("exception: recursive fault while reporting\n", .{});
        },
        else => {},
    }
}

fn exceptionName(info: Exception.Info) []const u8 {
    return switch (info.type) {
        .prefetch_abort => switch (info.fault.status()) {
            _ => "Prefetch Abort",
            inline else => |status| std.fmt.comptimePrint("({t}) Prefetch Abort", .{status}),
        },
        .data_abort => switch (info.fault.operation) {
            inline else => |op| switch (info.fault.status()) {
                _ => std.fmt.comptimePrint("({t}) Data Abort", .{op}),
                inline else => |status| std.fmt.comptimePrint("({t}, {t}) Data Abort", .{ op, status }),
            },
        },
        .undefined => "Illegal Instruction",
        .vfp => "Arithmetic Exception",
    };
}

fn writeExceptionReport(
    writer: *std.Io.Writer,
    name: []const u8,
    info: *const Exception.Info,
    registers: *const Exception.Registers,
) std.Io.Writer.Error!void {
    const r = registers.gpr;
    try writer.print(
        \\Aether {s}
        \\PC=0x{x:0>8} LR=0x{x:0>8} SP=0x{x:0>8}
        \\FAR=0x{x:0>8} FSR=0x{x:0>8} CPSR=0x{x:0>8}
        \\R0=0x{x:0>8} R1=0x{x:0>8} R2=0x{x:0>8} R3=0x{x:0>8}
        \\
    , .{
        name,
        r[15],
        r[14],
        r[13],
        info.address,
        @as(u32, @bitCast(info.fault)),
        registers.cpsr,
        r[0],
        r[1],
        r[2],
        r[3],
    });
}

fn writeGenericReport(
    writer: *std.Io.Writer,
    name: []const u8,
    addr: ?usize,
    opt_ctx: ?std.debug.CpuContextPtr,
) std.Io.Writer.Error!void {
    if (opt_ctx) |ctx| {
        const r = ctx.r;
        try writer.print(
            \\Aether {s}
            \\PC=0x{x:0>8} LR=0x{x:0>8} SP=0x{x:0>8}
            \\FAR=0x{x:0>8}
            \\R0=0x{x:0>8} R1=0x{x:0>8} R2=0x{x:0>8} R3=0x{x:0>8}
            \\
        , .{
            name,
            r[15],
            r[14],
            r[13],
            addr orelse 0,
            r[0],
            r[1],
            r[2],
            r[3],
        });
    } else if (addr) |a| {
        try writer.print("Aether {s} at address 0x{x}\n", .{ name, a });
    } else {
        try writer.print("Aether {s} (no address available)\n", .{name});
    }
}

fn exceptionError(info: *const Exception.Info, registers: *const Exception.Registers) horizon.ErrorDisplayManager.FatalError {
    return .{
        .type = .exception,
        .revision_high = 0x00,
        .revision_low = 0x00,
        .result_code = .failure,
        .pc_address = @intCast(registers.gpr[15]),
        .process_id = @intFromEnum(horizon.getProcessId(.current).value),
        .title_id = 0x0,
        .applet_title_id = 0x0,
        .data = .{ .exception = .{
            .info = info.*,
            .registers = registers.*,
        } },
    };
}

fn failureError(name: []const u8, addr: ?usize, opt_ctx: ?std.debug.CpuContextPtr) horizon.ErrorDisplayManager.FatalError {
    return .{
        .type = .failure,
        .revision_high = 0x00,
        .revision_low = 0x00,
        .result_code = .failure,
        .pc_address = if (opt_ctx) |ctx| @intCast(ctx.r[15]) else @intCast(addr orelse 0xDEADBEEF),
        .process_id = @intFromEnum(horizon.getProcessId(.current).value),
        .title_id = 0x0,
        .applet_title_id = 0x0,
        .data = .{ .failure = .{
            .message = errorDisplayMessage(name, addr, opt_ctx),
        } },
    };
}

fn errorDisplayMessage(name: []const u8, addr: ?usize, opt_ctx: ?std.debug.CpuContextPtr) [0x60]u8 {
    var buffer: [0x60]u8 = @splat(0);
    var writer: std.Io.Writer = .fixed(&buffer);

    if (opt_ctx) |ctx| {
        writer.print("{s} PC={x:0>8} LR={x:0>8} SP={x:0>8} FAR={x:0>8}", .{
            shortName(name),
            ctx.r[15],
            ctx.r[14],
            ctx.r[13],
            addr orelse 0,
        }) catch {};
    } else {
        writer.print("{s} FAR={x:0>8}", .{ shortName(name), addr orelse 0 }) catch {};
    }

    return buffer;
}

fn shortName(name: []const u8) []const u8 {
    return if (name.len > 18) name[0..18] else name;
}
