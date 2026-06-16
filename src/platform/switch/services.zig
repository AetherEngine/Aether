//! Switch system services / entry shim.
//!
//! Exports a C-callable `main` that hands control to the user's Zig
//! `main`. The allocator and baseline `std.Io` pieces of `std.process.Init`
//! are wired through newlib; deeper platform services remain TODO.
//!
//! libnx's switch.specs links with `--require-defined=main`, which
//! pulls a strong `main` from libnx's crt0 by default. We shadow it
//! with this Zig export — same name, weakness doesn't matter since
//! ld picks the first definition seen — to route the entry through
//! Aether instead of libnx's nnMain wrapper.

const process_init = @import("aether").CProcessInit;
const std = @import("std");
const Cio = @import("aether").Cio;
const c = @cImport({
    @cUndef("_GNU_SOURCE");
    @cUndef("_DEFAULT_SOURCE");
    @cDefine("_POSIX_C_SOURCE", "200809L");
    @cDefine("wint_t", "__WINT_TYPE__");
    @cDefine("__SWITCH__", "1");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("stdio.h");
    @cInclude("switch/runtime/devices/console.h");
});

pub const os = struct {
    pub const PATH_MAX = 1024;
    pub const NAME_MAX = 255;
};

fn AppRoot() type {
    const root = @import("root");
    return if (@hasDecl(root, "main")) root else @import("aether_user_root");
}

pub const std_options = if (@hasDecl(AppRoot(), "std_options")) AppRoot().std_options else std.Options{};
pub const std_options_debug_threaded_io = if (@hasDecl(AppRoot(), "std_options_debug_threaded_io")) AppRoot().std_options_debug_threaded_io else null;
pub const std_options_debug_io = if (@hasDecl(AppRoot(), "std_options_debug_io")) AppRoot().std_options_debug_io else std.Io.failing;
const app_std_options_cwd: ?fn () std.Io.Dir = if (@hasDecl(AppRoot(), "std_options_cwd")) AppRoot().std_options_cwd else null;
pub const std_options_cwd = app_std_options_cwd orelse @import("aether").Cio.cwd;

const fatal_result: u32 = 0xf801;
const FatalPolicy_ErrorScreen: c_int = 2;
const BreakReason_Panic: u32 = 0;

const CpuRegister = extern union {
    x: u64,
    w: u32,
    r: u32,
};

const FpuRegister = extern union {
    v: u128,
    d: f64,
    s: f32,
};

const ThreadExceptionDump = extern struct {
    error_desc: u32,
    pad: [3]u32,
    cpu_gprs: [29]CpuRegister,
    fp: CpuRegister,
    lr: CpuRegister,
    sp: CpuRegister,
    pc: CpuRegister,
    padding: u64,
    fpu_gprs: [32]FpuRegister,
    pstate: u32,
    afsr0: u32,
    afsr1: u32,
    esr: u32,
    far: CpuRegister,
};

const FatalAarch64Context = extern struct {
    x: [29]u64 = @splat(0),
    fp: u64 = 0,
    lr: u64 = 0,
    sp: u64 = 0,
    pc: u64 = 0,
    pstate: u64 = 0,
    afsr0: u64 = 0,
    afsr1: u64 = 0,
    esr: u64 = 0,
    far: u64 = 0,
    stack_trace: [32]u64 = @splat(0),
    start_address: u64 = 0,
    register_set_flags: u64 = 0,
    stack_trace_size: u32 = 0,
};

const FatalCpuContext = extern struct {
    aarch64_ctx: FatalAarch64Context = .{},
    is_aarch32: bool = false,
    typ: u32 = 0,
};

extern fn fatalThrowWithContext(err: u32, policy: c_int, ctx: *FatalCpuContext) void;
extern fn svcBreak(break_reason: u32, address: usize, size: usize) u32;
extern fn svcOutputDebugString(str: [*]const u8, size: u64) u32;
extern fn svcSleepThread(nano: i64) void;
extern fn appletMainLoop() bool;
extern fn consoleInit(console: ?*anyopaque) ?*anyopaque;
extern fn consoleUpdate(console: ?*anyopaque) void;
extern fn consoleClear() void;

// .text bounds provided by the Switch link step. The Zig C backend references
// these as externs, so build.zig provides both raw and zig_e_ names.
extern const __text_start: u8;
extern const __text_end: u8;

comptime {
    @export(&entry, .{ .name = "main" });
    @export(&exceptionHandler, .{ .name = "__libnx_exception_handler" });
}

var panic_stage: u8 = 0;
var program_stack_top: usize = 0;

export var __nx_exception_ignoredebug: u32 = 1;
export var __nx_exception_stack: [32 * 1024]u8 align(16) = undefined;
export const __nx_exception_stack_size: usize = __nx_exception_stack.len;

fn entry(_: c_int, _: [*c][*c]u8) callconv(.c) c_int {
    if (program_stack_top == 0) {
        program_stack_top = asm volatile ("mov %[top], sp"
            : [top] "=r" (-> usize),
        );
    }

    const init = process_init.makeInit(.{ .vector = {} });
    defer Cio.deinitNetworking();
    AppRoot().main(init) catch |err| {
        fatalMainError(err, @errorReturnTrace(), @returnAddress());
    };
    return 0;
}

fn getFramePointer() usize {
    return asm volatile ("mov %[fp], x29"
        : [fp] "=r" (-> usize),
    );
}

fn isLikelyReturnAddress(addr: usize) bool {
    @setRuntimeSafety(false);
    const ts = @intFromPtr(&__text_start);
    const te = @intFromPtr(&__text_end);
    if ((addr & 3) != 0 or addr < ts or addr >= te) return false;
    const prev = addr -% 4;
    if (prev < ts) return false;
    const inst = @as(*const u32, @ptrFromInt(prev)).*;
    if ((inst & 0xfc000000) == 0x94000000) return true; // bl imm26
    if ((inst & 0xfffffc1f) == 0xd63f0000) return true; // blr xn
    return false;
}

fn collectStackAddresses(first_addr: usize, out: []usize, start_fp: ?usize, start_lr: ?usize, start_sp: ?usize) usize {
    @setRuntimeSafety(false);
    const min_valid_fp: usize = 0x100000;
    var count: usize = 0;
    if (out.len > 0) {
        out[0] = first_addr;
        count = 1;
    }
    if (start_lr) |lr| {
        if (lr > 1 and lr != first_addr and count < out.len and isLikelyReturnAddress(lr)) {
            out[count] = lr;
            count += 1;
        }
    }

    var fp = start_fp orelse getFramePointer();
    var guard: usize = 0;
    while (count < out.len and guard < 64) : (guard += 1) {
        if (fp < min_valid_fp or (fp & 7) != 0) break;
        const saved_fp: *const u64 = @ptrFromInt(fp);
        const saved_lr: *const u64 = @ptrFromInt(fp + 8);
        const lr: usize = @intCast(saved_lr.*);
        const next_fp: usize = @intCast(saved_fp.*);
        if (lr > 1 and count < out.len and isLikelyReturnAddress(lr)) {
            out[count] = lr;
            count += 1;
        }
        if (next_fp < min_valid_fp or next_fp == 0 or next_fp <= fp or (next_fp & 7) != 0) break;
        fp = next_fp;
    }

    if (start_sp) |sp| {
        var top = if (program_stack_top != 0) program_stack_top else sp +% (1024 * 1024);
        if (top <= sp or top -% sp > 8 * 1024 * 1024 or sp < 0x1000) {
            top = sp +% (64 * 1024);
        }
        var scan = sp & ~@as(usize, 7);
        const max_scan: usize = 8 * 1024 * 1024;
        var scanned: usize = 0;
        while (scan < top and count < out.len and scanned < max_scan) : ({
            scan += @sizeOf(usize);
            scanned += @sizeOf(usize);
        }) {
            if (scan < 0x1000) break;
            const val = @as(*const usize, @ptrFromInt(scan)).*;
            if (isLikelyReturnAddress(val)) {
                var have = false;
                for (out[0..count]) |prev| if (prev == val) {
                    have = true;
                    break;
                };
                if (!have) {
                    out[count] = val;
                    count += 1;
                }
            }
        }
    }

    return count;
}

fn showCrashScreen(title: []const u8, message: []const u8, pc: usize, stack: []const usize) void {
    @setRuntimeSafety(false);

    _ = consoleInit(null);
    consoleClear();

    consolePrint("\x1b[31;1m{s}\x1b[0m\n\n", .{title});
    if (message.len != 0) {
        consoleWrite(message);
        if (message[message.len - 1] != '\n') consoleWrite("\n");
        consoleWrite("\n");
    }

    const base = @intFromPtr(&__text_start);
    const text_end = @intFromPtr(&__text_end);
    consolePrint("Backtrace start addr = 0x{x}\n", .{base});
    if (pc != 0) {
        consolePrint("PC = 0x{x}", .{pc});
        if (pc >= base and pc < text_end) consolePrint(" (+0x{x})", .{pc - base});
        consoleWrite("\n");
    }

    const show = @min(stack.len, 24);
    for (stack[0..show], 0..) |addr, i| {
        consolePrint("BT{d} = 0x{x}", .{ i, addr });
        if (addr >= base and addr < text_end) consolePrint(" (+0x{x})", .{addr - base});
        consoleWrite("\n");
    }
    if (show == 0 and pc != 0) {
        consolePrint("BT0 = 0x{x}", .{pc});
        if (pc >= base and pc < text_end) consolePrint(" (+0x{x})", .{pc - base});
        consoleWrite("\n");
    }

    consoleWrite("\nClose the app from HOME after recording this screen.\n");
    consoleUpdate(null);
    waitOnCrashScreen();
}

fn waitOnCrashScreen() void {
    @setRuntimeSafety(false);

    while (appletMainLoop()) {
        consoleUpdate(null);
        svcSleepThread(16 * 1000 * 1000);
    }
}

fn consolePrint(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    fixed.print(fmt, args) catch {};
    consoleWrite(fixed.buffered());
}

fn consoleWrite(message: []const u8) void {
    var rest = message;
    while (rest.len != 0) {
        const n = @min(rest.len, @as(usize, @intCast(std.math.maxInt(c_int))));
        _ = c.printf("%.*s", @as(c_int, @intCast(n)), rest.ptr);
        rest = rest[n..];
    }
}

fn fatalMainError(err: anyerror, maybe_trace: ?*std.builtin.StackTrace, fallback_addr: usize) noreturn {
    @branchHint(.cold);
    @setRuntimeSafety(false);

    if (panic_stage != 0) {
        fatalDisplay("Aether recursive error in main");
    }
    panic_stage = 1;

    const main_pc = if (maybe_trace) |trace| blk: {
        const nn = @min(trace.index, trace.instruction_addresses.len);
        if (nn > 0) break :blk trace.instruction_addresses[0];
        break :blk fallback_addr;
    } else fallback_addr;

    const entry_fp = asm volatile ("mov %[fp], x29"
        : [fp] "=r" (-> usize),
    );
    const entry_lr = asm volatile ("mov %[lr], x30"
        : [lr] "=r" (-> usize),
    );
    const entry_sp = asm volatile ("mov %[sp], sp"
        : [sp] "=r" (-> usize),
    );

    var addrs: [32]usize = undefined;
    const n = collectStackAddresses(main_pc, &addrs, entry_fp, entry_lr, entry_sp);

    var trace_buf: [768]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&trace_buf);

    fixed.print("Aether main returned error.{s} at 0x{x}\n", .{ @errorName(err), main_pc }) catch {};
    fixed.print("entry_fp=0x{x} entry_sp=0x{x}\n", .{ entry_fp, entry_sp }) catch {};

    if (maybe_trace) |trace| {
        const nerr = @min(trace.index, trace.instruction_addresses.len);
        if (nerr > 0) {
            fixed.writeAll("error return trace:\n") catch {};
            for (trace.instruction_addresses[0..nerr], 0..) |a, i| {
                fixed.print("{d: >2}: 0x{x:0>16}\n", .{ i, a }) catch {};
            }
        }
    }

    fixed.writeAll("stack trace:\n") catch {};
    const show = @min(n, 24);
    for (addrs[0..show], 0..) |a, i| {
        fixed.print("{d: >2}: 0x{x:0>16}\n", .{ i, a }) catch {};
    }

    const text = fixed.buffered();
    debugString(text);
    debugString("\n");
    showCrashScreen("Aether main error", text, main_pc, addrs[0..n]);
    fatalWithContext(main_pc, entry_fp, entry_lr, entry_sp, 0, 0, 0, 0, addrs[0..n], 0);
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    @setRuntimeSafety(false);

    if (panic_stage != 0) {
        fatalDisplay("Aether recursive panic");
    }
    panic_stage = 1;

    const first = first_trace_addr orelse @returnAddress();
    const entry_fp = asm volatile ("mov %[fp], x29"
        : [fp] "=r" (-> usize),
    );
    const entry_lr = asm volatile ("mov %[lr], x30"
        : [lr] "=r" (-> usize),
    );
    const entry_sp = asm volatile ("mov %[sp], sp"
        : [sp] "=r" (-> usize),
    );

    var addrs: [64]usize = undefined;
    const n = collectStackAddresses(first, &addrs, entry_fp, entry_lr, entry_sp);

    var trace_buf: [768]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&trace_buf);

    fixed.print("Aether panic at 0x{x}: {s}\n", .{ first, msg }) catch {};
    fixed.print("entry_fp=0x{x} entry_sp=0x{x}\n", .{ entry_fp, entry_sp }) catch {};

    if (@errorReturnTrace()) |t| {
        const nerr = @min(t.index, t.instruction_addresses.len);
        if (nerr > 0) {
            fixed.writeAll("error return trace:\n") catch {};
            for (t.instruction_addresses[0..nerr], 0..) |a, i| {
                fixed.print("{d: >2}: 0x{x:0>16}\n", .{ i, a }) catch {};
            }
        }
    }

    fixed.writeAll("stack trace:\n") catch {};
    const show = @min(n, 32);
    for (addrs[0..show], 0..) |a, i| {
        fixed.print("{d: >2}: 0x{x:0>16}\n", .{ i, a }) catch {};
    }
    if (n == 0) {
        fixed.print("0: 0x{x:0>16}\n", .{first}) catch {};
    }

    const text = fixed.buffered();
    debugString(text);
    debugString("\n");
    showCrashScreen("Aether panic", text, first, addrs[0..n]);
    fatalWithContext(first, entry_fp, entry_lr, entry_sp, 0, 0, 0, 0, addrs[0..n], 0);
}

fn exceptionHandler(dump: *ThreadExceptionDump) callconv(.c) noreturn {
    @branchHint(.cold);
    @setRuntimeSafety(false);

    const pc: usize = @intCast(dump.pc.x);
    const fp: usize = @intCast(dump.fp.x);
    const lr: usize = @intCast(dump.lr.x);
    const sp: usize = @intCast(dump.sp.x);

    var addrs: [32]usize = undefined;
    const n = collectStackAddresses(pc, &addrs, fp, lr, sp);

    var buf: [768]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buf);
    fixed.print(
        \\Aether {s}
        \\PC=0x{x:0>16} LR=0x{x:0>16} SP=0x{x:0>16}
        \\FAR=0x{x:0>16} ESR=0x{x:0>8} PSTATE=0x{x:0>8}
        \\X0=0x{x:0>16} X1=0x{x:0>16} X2=0x{x:0>16} X3=0x{x:0>16}
        \\stack trace:
        \\
    , .{
        exceptionName(dump.error_desc),
        pc,
        lr,
        sp,
        dump.far.x,
        dump.esr,
        dump.pstate,
        dump.cpu_gprs[0].x,
        dump.cpu_gprs[1].x,
        dump.cpu_gprs[2].x,
        dump.cpu_gprs[3].x,
    }) catch {};
    const show = @min(n, 24);
    for (addrs[0..show], 0..) |a, i| {
        fixed.print("{d: >2}: 0x{x:0>16}\n", .{ i, a }) catch {};
    }

    const text = fixed.buffered();
    debugString(text);
    debugString("\n");
    showCrashScreen("Aether CPU exception", text, pc, addrs[0..n]);

    fatalWithContext(
        pc,
        fp,
        lr,
        sp,
        dump.pstate,
        dump.afsr0,
        dump.afsr1,
        dump.esr,
        addrs[0..n],
        dump.error_desc,
    );
}

fn exceptionName(desc: u32) []const u8 {
    return switch (desc) {
        0x100 => "Instruction Abort",
        0x102 => "Misaligned PC",
        0x103 => "Misaligned SP",
        0x106 => "SError",
        0x301 => "Bad SVC",
        0x104 => "CPU Trap",
        0x101 => "CPU Exception",
        else => "CPU Exception",
    };
}

fn fatalWithContext(
    pc: usize,
    fp: usize,
    lr: usize,
    sp: usize,
    pstate: u32,
    afsr0: u32,
    afsr1: u32,
    esr: u32,
    stack: []const usize,
    typ: u32,
) noreturn {
    var ctx: FatalCpuContext = .{};
    ctx.typ = typ;
    ctx.aarch64_ctx.fp = fp;
    ctx.aarch64_ctx.lr = lr;
    ctx.aarch64_ctx.sp = sp;
    ctx.aarch64_ctx.pc = pc;
    ctx.aarch64_ctx.pstate = pstate;
    ctx.aarch64_ctx.afsr0 = afsr0;
    ctx.aarch64_ctx.afsr1 = afsr1;
    ctx.aarch64_ctx.esr = esr;
    ctx.aarch64_ctx.register_set_flags = (@as(u64, 1) << 29) | (@as(u64, 1) << 30) | (@as(u64, 1) << 31);

    const n = @min(stack.len, ctx.aarch64_ctx.stack_trace.len);
    for (stack[0..n], 0..) |addr, i| {
        ctx.aarch64_ctx.stack_trace[i] = @intCast(addr);
    }
    ctx.aarch64_ctx.stack_trace_size = @intCast(n);

    fatalThrowWithContext(fatal_result, FatalPolicy_ErrorScreen, &ctx);
    _ = svcBreak(BreakReason_Panic, 0, 0);
    while (true) {}
}

fn fatalDisplay(message: [:0]const u8) noreturn {
    debugString(message);
    debugString("\n");
    showCrashScreen("Aether fatal error", message, 0, &.{});
    _ = svcBreak(BreakReason_Panic, @intFromPtr(message.ptr), message.len);
    while (true) {}
}

fn debugString(message: []const u8) void {
    if (message.len == 0) return;
    _ = svcOutputDebugString(message.ptr, @intCast(message.len));
}
