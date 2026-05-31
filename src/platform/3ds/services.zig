//! 3DS system services / entry shim.
//!
//! Exports a C-callable `main` that hands control to the user's Zig
//! `main`. The allocator and baseline `std.Io` pieces of `std.process.Init`
//! are wired through newlib; deeper platform services remain TODO.
//!
//! Stack default: libctru's 32 KB is far too small for any std-using
//! Zig code path. We override `__stacksize__` (a `WEAK` symbol in
//! libctru) with a strong export. 1 MB is comfortable; bump if engine
//! frames grow.
//!
//! libctru also creates service threads internally. NDSP currently asks for
//! a 4 KB stack, which can underflow in its sound-frame worker before Aether
//! code is on the stack. The 3DS link step wraps `threadCreate`, and the
//! wrapper below raises tiny service-thread stacks to a conservative floor.

const process_init = @import("../c_process_init.zig");
const std = @import("std");

const argv = [_][*:0]const u8{"Aether"};
const min_service_thread_stack = 128 * 1024;
const exception_stack_size = 16 * 1024;
const fatal_result: c_int = -1;
const USERBREAK_PANIC = 0;

const Thread = ?*anyopaque;
const ThreadFunc = *const fn (?*anyopaque) callconv(.c) void;
const ExceptionInfo = extern struct {
    typ: c_int,
    reserved: [3]u8,
    fsr: u32,
    far: u32,
    fpexc: u32,
    fpinst: u32,
    fpinst2: u32,
};
const CpuRegisters = extern struct {
    r: [13]u32,
    sp: u32,
    lr: u32,
    pc: u32,
    cpsr: u32,
};

extern fn __real_threadCreate(
    entrypoint: ThreadFunc,
    arg: ?*anyopaque,
    stack_size: usize,
    prio: c_int,
    core_id: c_int,
    detached: bool,
) Thread;

extern fn aether3dsInstallExceptionHandler(stack_top: ?*anyopaque) void;
extern fn errfInit() c_int;
extern fn ERRF_SetUserString(user_string: [*:0]const u8) c_int;
extern fn ERRF_ThrowResultWithMessage(failure: c_int, message: [*:0]const u8) c_int;
extern fn ERRF_ExceptionHandler(excep: *ExceptionInfo, regs: *CpuRegisters) noreturn;
extern fn svcBreak(break_reason: c_int) void;
extern fn svcOutputDebugString(str: [*]const u8, length: i32) c_int;

comptime {
    @export(&entry, .{ .name = "main" });
    @export(&stack_size, .{ .name = "__stacksize__" });
    @export(&threadCreateWrap, .{ .name = "__wrap_threadCreate" });
    @export(&exceptionHandler, .{ .name = "aether3dsExceptionHandler" });
}

var stack_size: u32 = 1 * 1024 * 1024;
var exception_stack: [exception_stack_size]u8 align(8) = undefined;
var panic_stage: u8 = 0;

fn threadCreateWrap(
    entrypoint: ThreadFunc,
    arg: ?*anyopaque,
    requested_stack_size: usize,
    prio: c_int,
    core_id: c_int,
    detached: bool,
) callconv(.c) Thread {
    return __real_threadCreate(
        entrypoint,
        arg,
        @max(requested_stack_size, min_service_thread_stack),
        prio,
        core_id,
        detached,
    );
}

fn entry() callconv(.c) c_int {
    installCrashHandlers();

    const init = process_init.makeInit(.{ .vector = &argv });
    @import("root").main(init) catch |err| {
        fatalMainError(err, @errorReturnTrace(), @returnAddress());
    };
    return 0;
}

fn fatalMainError(err: anyerror, maybe_trace: ?*std.builtin.StackTrace, fallback_addr: usize) noreturn {
    if (maybe_trace) |trace| {
        const len = @min(trace.instruction_addresses.len, trace.index);
        const addrs = trace.instruction_addresses[0..@min(len, 4)];
        switch (addrs.len) {
            0 => {},
            1 => fatal("Aether main returned error.{s} at 0x{x}", .{ @errorName(err), addrs[0] }),
            2 => fatal("Aether main returned error.{s} at 0x{x} 0x{x}", .{ @errorName(err), addrs[0], addrs[1] }),
            3 => fatal("Aether main returned error.{s} at 0x{x} 0x{x} 0x{x}", .{ @errorName(err), addrs[0], addrs[1], addrs[2] }),
            else => fatal("Aether main returned error.{s} at 0x{x} 0x{x} 0x{x} 0x{x}", .{ @errorName(err), addrs[0], addrs[1], addrs[2], addrs[3] }),
        }
    }

    fatal("Aether main returned error.{s} at 0x{x}", .{ @errorName(err), fallback_addr });
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);

    if (panic_stage != 0) {
        fatalDisplay("Aether recursive panic");
    }
    panic_stage = 1;

    fatal("Aether panic at 0x{x}: {s}", .{ first_trace_addr orelse @returnAddress(), msg });
}

fn installCrashHandlers() void {
    const top: ?*anyopaque = @ptrFromInt(@intFromPtr(&exception_stack) + exception_stack.len);
    aether3dsInstallExceptionHandler(top);
}

fn exceptionHandler(excep: *ExceptionInfo, regs: *CpuRegisters) callconv(.c) noreturn {
    @branchHint(.cold);

    var buf: [256:0]u8 = @splat(0);
    const msg = std.fmt.bufPrintZ(&buf,
        \\Aether {s}
        \\PC=0x{x:0>8} LR=0x{x:0>8} SP=0x{x:0>8}
        \\FAR=0x{x:0>8} FSR=0x{x:0>8} CPSR=0x{x:0>8}
        \\R0=0x{x:0>8} R1=0x{x:0>8} R2=0x{x:0>8} R3=0x{x:0>8}
    , .{
        exceptionName(excep.typ),
        regs.pc,
        regs.lr,
        regs.sp,
        excep.far,
        excep.fsr,
        regs.cpsr,
        regs.r[0],
        regs.r[1],
        regs.r[2],
        regs.r[3],
    }) catch fallback: {
        @memcpy(buf[0.."Aether CPU exception".len], "Aether CPU exception");
        break :fallback buf[0.."Aether CPU exception".len :0];
    };

    debugString(msg);
    debugString("\n");
    _ = errfInit();
    _ = ERRF_SetUserString(msg.ptr);
    ERRF_ExceptionHandler(excep, regs);
}

fn exceptionName(typ: c_int) []const u8 {
    return switch (typ) {
        0 => "Prefetch Abort",
        1 => "Data Abort",
        2 => "Undefined Instruction",
        3 => "VFP Exception",
        else => "CPU Exception",
    };
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [256:0]u8 = @splat(0);
    const msg = std.fmt.bufPrintZ(&buf, fmt, args) catch fallback: {
        @memcpy(buf[0.."Aether fatal error".len], "Aether fatal error");
        break :fallback buf[0.."Aether fatal error".len :0];
    };
    fatalDisplay(msg);
}

fn fatalDisplay(message: [:0]const u8) noreturn {
    debugString(message);
    debugString("\n");

    _ = errfInit();
    _ = ERRF_SetUserString(message.ptr);
    _ = ERRF_ThrowResultWithMessage(fatal_result, message.ptr);

    svcBreak(USERBREAK_PANIC);
    while (true) {}
}

fn debugString(message: []const u8) void {
    if (message.len == 0) return;
    _ = svcOutputDebugString(message.ptr, @intCast(@min(message.len, std.math.maxInt(i32))));
}
