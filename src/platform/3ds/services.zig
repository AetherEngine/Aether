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
//! libctru also exposes weak `__ctru_heap_size` and
//! `__ctru_linear_heap_size` symbols. Aether keeps the regular heap small
//! and routes its process allocator through linear memory, so export strong
//! values from build config instead of asking libctru for its default split.
//!
//! libctru also creates service threads internally. NDSP currently asks for
//! a 4 KB stack, which can underflow in its sound-frame worker before Aether
//! code is on the stack. The 3DS link step wraps `threadCreate`, and the
//! wrapper below raises tiny service-thread stacks to a conservative floor.

const process_init = @import("aether").CProcessInit;
const std = @import("std");
const options = @import("options");

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

// .text bounds provided by the linker script fragment in build.zig
// (using ADDR(.text) + SIZEOF(.text)) so the panic unwinder can
// precisely know what is code vs data/rodata/string literals when
// doing the low-confidence stack scan (and BL-prev check). This
// replaces any sketchy hardcoded ranges for "is this value in .text?".
extern const __text_start: u8;
extern const __text_end: u8;

comptime {
    @export(&entry, .{ .name = "main" });
    @export(&stack_size, .{ .name = "__stacksize__" });
    @export(&heap_size, .{ .name = "__ctru_heap_size" });
    @export(&linear_heap_size, .{ .name = "__ctru_linear_heap_size" });
    @export(&threadCreateWrap, .{ .name = "__wrap_threadCreate" });
    @export(&exceptionHandler, .{ .name = "aether3dsExceptionHandler" });
}

var stack_size: u32 = 1 * 1024 * 1024;
var heap_size: u32 = options.config.nintendo_3ds_heap_size;
var linear_heap_size: u32 = options.config.nintendo_3ds_linear_heap_size;
var exception_stack: [exception_stack_size]u8 align(8) = undefined;
var panic_stage: u8 = 0;
/// Captured very early in entry() so that the panic walker can scan the full
/// used stack up to the initial top (instead of an arbitrary small window).
var program_stack_top: usize = 0;

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
    if (program_stack_top == 0) {
        // Capture the SP as set by the 3DS crt0 / loader, before we push anything.
        // This is the "stack top" (high address); the base is roughly top - stack_size.
        program_stack_top = asm volatile ("mov %[top], sp" : [top] "=r" (-> usize));
    }
    installCrashHandlers();

    const init = process_init.makeInit(.{ .vector = &argv });
    AppRoot().main(init) catch |err| {
        fatalMainError(err, @errorReturnTrace(), @returnAddress());
    };
    return 0;
}

fn getFramePointer() usize {
    return asm volatile ("mov %[fp], r11" : [fp] "=r" (-> usize));
}

/// Returns true if `addr` looks like a plausible ARM return address (i.e. the
/// address immediately after a `bl` / `blx` instruction in .text).
/// Used to filter the low-confidence stack scan so we don't pollute the trace
/// with string constants, literal pools, or random data that happen to be in
/// the code address range.
fn isLikelyReturnAddress(addr: usize) bool {
    @setRuntimeSafety(false);
    const ts = @intFromPtr(&__text_start);
    const te = @intFromPtr(&__text_end);
    if ((addr & 3) != 0 or addr < ts or addr >= te) return false;
    const prev = addr -% 4;
    if (prev < ts) return false;
    const inst = @as(*const u32, @ptrFromInt(prev)).*;
    // ARM branch with link (BL) encoding: bits [27:24] == 0b1011 (0xb)
    // Covers unconditional and conditional BL.
    const op = (inst >> 24) & 0xf;
    if (op == 0xb) return true;
    return false;
}

/// Manual frame-pointer walk to collect return addresses for panic reporting.
/// Limited depth, best-effort (unsafe during crash is acceptable).
/// On 3DS (C-emitted code via gcc, often with omitted frame pointers), r11
/// may not be a valid FP; we defensively reject low/implausible values to
/// avoid data aborts inside the panic handler itself (which would turn a
/// nice panic into a CPU exception).
///
/// start_fp / start_lr (if provided) should be captured *very early* in the
/// panic handler (before the function's own frame setup or calls) so that
/// they reflect the caller's frame (the code that hit the panic/unreachable).
fn collectStackAddresses(first_addr: usize, out: []usize, start_fp: ?usize, start_lr: ?usize, start_sp: ?usize) usize {
    @setRuntimeSafety(false); // best-effort only; raw ptr walks can fault (caught by exception handler). Prevents safety checks here from causing recursive zig panic().
    const min_valid_fp: usize = 0x100000; // below this is not plausible for user stack frames on 3DS
    var count: usize = 0;
    if (out.len > 0) {
        out[0] = first_addr;
        count = 1;
    }
    // Prefer the provided start_lr (often the return addr from the panicking bl site)
    if (start_lr) |lr| {
        if (lr > 1 and lr != first_addr and count < out.len and isLikelyReturnAddress(lr)) {
            out[count] = lr;
            count += 1;
        }
    }
    var fp = start_fp orelse getFramePointer();
    var guard: usize = 0;
    while (count < out.len and guard < 64) : (guard += 1) {  // allow deeper for panic
        if (fp < min_valid_fp or (fp & 3) != 0) break;
        const saved_fp: *const u32 = @ptrFromInt(fp);
        const saved_lr: *const u32 = @ptrFromInt(fp + 4);
        const lr = saved_lr.*;
        const next_fp = saved_fp.*;
        if (lr > 1 and count < out.len and isLikelyReturnAddress(lr)) {
            out[count] = lr;
            count += 1;
        }
        // Downward-growing stack: outer (caller) frames have *higher* fp values than inner.
        // Walk while next_fp > fp. Stop on invalid, zero, misaligned, or non-progress (next <= fp would be cycle or wrong dir).
        if (next_fp < min_valid_fp or next_fp == 0 or next_fp <= fp or (next_fp & 3) != 0) break;
        fp = next_fp;
    }

    // Low-confidence heuristic stack scan for more entries (even if FP chain is broken,
    // which is common on 3DS C-backend). Scan for values that look like code addresses
    // (aligned, in plausible .text range). Useful for deeper traces on null unwraps etc.
    // We dedup and accept some noise because "crashing anyway". Larger window and
    // looser filter to get more candidates as requested.
    if (start_sp) |sp| {
        var top = if (program_stack_top != 0) program_stack_top else sp +% (1024 * 1024);
        // Extra sanity on top/sp to avoid absurdly large scans or bad windows if
        // program_stack_top got clobbered or capture was off. Cap total scan to 2MB.
        if (top <= sp or top -% sp > 2 * 1024 * 1024 or sp < 0x1000 or top > 0x30000000) {
            top = sp +% (64 * 1024); // small safe fallback window
        }
        // Scan the entire used stack (from current SP up to the initial top).
        // With isLikelyReturnAddress() this is safe and will only pick real RAs
        // that were saved by bl instructions, even across the full stack depth.
        // We still dedup and bound the number added.
        var scan: usize = sp & ~@as(usize, 3);
        const max_scan: usize = 2 * 1024 * 1024;
        var scanned: usize = 0;
        while (scan < top and count < out.len and scanned < max_scan) : ({
            scan += 4;
            scanned += 4;
        }) {
            if (scan < 0x1000 or scan > 0x30000000) break;
            const val = @as(*const u32, @ptrFromInt(scan)).*;
            if (isLikelyReturnAddress(val)) {
                var have = false;
                for (out[0..count]) |prev| if (prev == val) { have = true; break; };
                if (!have) {
                    out[count] = val;
                    count += 1;
                }
            }
        }
    }

    return count;
}

fn fatalMainError(err: anyerror, maybe_trace: ?*std.builtin.StackTrace, fallback_addr: usize) noreturn {
    @branchHint(.cold);
    @setRuntimeSafety(false); // best-effort crash reporting only; disables safety checks that could re-invoke panic() and produce "Aether recursive..." instead of the original info.

    if (panic_stage != 0) {
        fatalDisplay("Aether recursive error in main");
    }
    panic_stage = 1;

    const main_pc = if (maybe_trace) |trace| blk: {
        const nn = @min(trace.index, trace.instruction_addresses.len);
        if (nn > 0) break :blk trace.instruction_addresses[0];
        break :blk fallback_addr;
    } else fallback_addr;

    // Capture fp/lr/sp early for better starting point for walk (see panic() for details).
    const entry_fp = asm volatile ("mov %[fp], r11" : [fp] "=r" (-> usize));
    const entry_lr = asm volatile ("mov %[lr], lr" : [lr] "=r" (-> usize));
    const entry_sp = asm volatile ("mov %[sp], sp" : [sp] "=r" (-> usize));

    var addrs: [32]usize = undefined;
    const n = collectStackAddresses(main_pc, &addrs, entry_fp, entry_lr, entry_sp);

    var trace_buf: [512]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&trace_buf);

    fixed.print("Aether main returned error.{s} at 0x{x}\n", .{@errorName(err), main_pc}) catch {};
    fixed.print("entry_fp=0x{x} entry_sp=0x{x}\n", .{entry_fp, entry_sp}) catch {};

    if (maybe_trace) |trace| {
        const nerr = @min(trace.index, trace.instruction_addresses.len);
        if (nerr > 0) {
            fixed.writeAll("error return trace:\n") catch {};
            for (trace.instruction_addresses[0..nerr], 0..) |a, i| {
                fixed.print("{d: >2}: 0x{x:0>8}\n", .{ i, a }) catch {};
            }
        }
    }

    // Current stack walk for more context (seeded from entry + heuristic)
    fixed.writeAll("stack trace:\n") catch {};
    const show = @min(n, 20);
    for (addrs[0..show], 0..) |a, i| {
        fixed.print("{d: >2}: 0x{x:0>8}\n", .{ i, a }) catch {};
    }

    fixed.writeAll("\n") catch {};
    const text = fixed.buffered();

    debugString(text);
    debugString("\n");

    // For ERRF_SetUserString (max ~256 bytes), compact version with PC + stack addrs.
    var user_buf: [256:0]u8 = @splat(0);
    var uw: std.Io.Writer = .fixed(&user_buf);
    var hbuf: [96]u8 = undefined;
    const h = std.fmt.bufPrint(&hbuf, "Aether main err at 0x{x}: {s}\n", .{main_pc, @errorName(err)}) catch "Aether main err\n";
    uw.writeAll(h[0..@min(h.len, 70)]) catch {};
    if (maybe_trace) |trace| {
        const nerr = @min(trace.index, trace.instruction_addresses.len);
        if (nerr > 0) {
            uw.writeAll("err:") catch {};
            for (trace.instruction_addresses[0..@min(nerr,3)], 0..) |a, i| {
                uw.print(" {d}:0x{x}", .{i, a}) catch {};
            }
            uw.writeAll("\n") catch {};
        }
    }
    uw.writeAll("stack:") catch {};
    const nprint = @min(n, 24);
    for (addrs[0..nprint], 0..) |a, i| {
        uw.print(" {d}:0x{x}", .{i, a}) catch {};
    }
    uw.writeAll("\n") catch {};
    const end = @min(uw.end, 255);
    const user_str = user_buf[0..end :0];

    _ = errfInit();
    _ = ERRF_SetUserString(user_str.ptr);

    // Compact message for the visible "Reason" (0x60 limit): include the PC + some stack.
    var throw_buf: [0x60:0]u8 = @splat(0);
    var w: std.Io.Writer = .fixed(&throw_buf);
    w.print("Aether main err at 0x{x}: {s}", .{main_pc, @errorName(err)}) catch {};
    if (n > 0) {
        w.print(" [", .{}) catch {};
        const max_short = 4;
        for (addrs[0..@min(n, max_short)], 0..) |a, i| {
            if (i > 0) w.print(" ", .{}) catch {};
            w.print("{d}:0x{x}", .{i, a}) catch {};
        }
        if (n > max_short) w.print("..", .{}) catch {};
        w.print("]", .{}) catch {};
    }
    _ = w.flush() catch {};
    _ = ERRF_ThrowResultWithMessage(fatal_result, &throw_buf);

    svcBreak(USERBREAK_PANIC);
    while (true) {}
}

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, first_trace_addr: ?usize) noreturn {
    @branchHint(.cold);
    @setRuntimeSafety(false); // best-effort crash reporting only; disables safety checks that could re-invoke panic() and produce "Aether recursive..." instead of the original info.

    if (panic_stage != 0) {
        fatalDisplay("Aether recursive panic");
    }
    panic_stage = 1;

    const first = first_trace_addr orelse @returnAddress();

    // Capture fp/lr/sp *immediately* at entry (before any local stack alloc or calls
    // that might clobber r11 in the generated prologue). This gives us the fp of
    // the frame that called the panic handler (i.e. the function containing the
    // unreachable/panic site). sp is used for low-conf heuristic scan.
    const entry_fp = asm volatile ("mov %[fp], r11" : [fp] "=r" (-> usize));
    const entry_lr = asm volatile ("mov %[lr], lr" : [lr] "=r" (-> usize));
    const entry_sp = asm volatile ("mov %[sp], sp" : [sp] "=r" (-> usize));

    // Collect early, passing the captured entry context so the walker starts
    // from the caller's frame (not inside the panic handler). Larger array + sp
    // scan for more (even low-confidence) frames.
    var addrs: [64]usize = undefined;
    const n = collectStackAddresses(first, &addrs, entry_fp, entry_lr, entry_sp);

    var trace_buf: [512]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&trace_buf);

    fixed.print("Aether panic at 0x{x}: {s}\n", .{first, msg}) catch {};
    // entry_fp / entry_sp are printed here for the svc debug output (3dslink etc.)
    // They are omitted from the short user_str to keep the error screen clean.
    fixed.print("entry_fp=0x{x} entry_sp=0x{x}\n", .{entry_fp, entry_sp}) catch {};

    // error return trace (if any)
    if (@errorReturnTrace()) |t| {
        const nerr = @min(t.index, t.instruction_addresses.len);
        if (nerr > 0) {
            fixed.writeAll("error return trace:\n") catch {};
            for (t.instruction_addresses[0..nerr], 0..) |a, i| {
                fixed.print("{d: >2}: 0x{x:0>8}\n", .{ i, a }) catch {};
            }
        }
    }

    // current stack via manual fp walk (seeded from entry + walked from caller's fp)
    // + heuristic scan (filtered to likely RAs). Skip internal safety panic
    // handler frames (they are just noise in the trace).
    fixed.writeAll("stack trace:\n") catch {};
    const show = @min(n, 32);
    for (addrs[0..show], 0..) |a, i| {
        fixed.print("{d: >2}: 0x{x:0>8}\n", .{ i, a }) catch {};
    }
    if (n == 0) {
        fixed.print("0: 0x{x:0>8}\n", .{first}) catch {};
    }

    const text = fixed.buffered();

    debugString(text);
    debugString("\n");

    // For ERRF_SetUserString (max ~256 bytes per libctru), build a compact version
    // that prioritizes the PC + as many stack addresses as will fit. This is what
    // appears in CFW error screens / exception logs when the full Reason is limited.
    // The pretty multi-line version above still goes to debugString (visible via 3dslink etc.).
    var user_buf: [256:0]u8 = @splat(0);
    var uw: std.Io.Writer = .fixed(&user_buf);
    // Put the panic message first: ERRF surfaces have very little room, and
    // diagnostics often carry the useful measurement in `msg`.
    var hbuf: [96]u8 = undefined;
    const h = std.fmt.bufPrint(&hbuf, "{s}\npc=0x{x}\n", .{msg, first}) catch "Aether panic\n";
    uw.writeAll(h[0..@min(h.len, 70)]) catch {};
    if (@errorReturnTrace()) |t| {
        const nerr = @min(t.index, t.instruction_addresses.len);
        if (nerr > 0) {
            uw.writeAll("err:") catch {};
            for (t.instruction_addresses[0..@min(nerr,3)], 0..) |a, i| {
                uw.print(" {d}:0x{x}", .{i, a}) catch {};
            }
            uw.writeAll("\n") catch {};
        }
    }
    uw.writeAll("stack:") catch {};
    const nprint = @min(n, 30);
    for (addrs[0..nprint], 0..) |a, i| {
        uw.print(" {d}:0x{x}", .{i, a}) catch {};
    }
    if (nprint == 0) {
        uw.print(" 0:0x{x}", .{first}) catch {};
    }
    uw.writeAll("\n") catch {};
    const end = @min(uw.end, 255);
    const user_str = user_buf[0..end :0];

    _ = errfInit();
    _ = ERRF_SetUserString(user_str.ptr);

    // The failure message shown as "Reason" on the error screen is limited
    // (~0x60 bytes), so prioritize the measurement text over the PC/stack.
    var throw_buf: [0x60:0]u8 = @splat(0);
    var w: std.Io.Writer = .fixed(&throw_buf);
    w.print("{s} pc=0x{x}", .{msg, first}) catch {};
    if (n > 0) {
        w.print(" [", .{}) catch {};
        const max_short = 4;
        for (addrs[0..@min(n, max_short)], 0..) |a, i| {
            if (i > 0) w.print(" ", .{}) catch {};
            w.print("{d}:0x{x}", .{i, a}) catch {};
        }
        if (n > max_short) w.print("..", .{}) catch {};
        w.print("]", .{}) catch {};
    }
    _ = w.flush() catch {};
    _ = ERRF_ThrowResultWithMessage(fatal_result, &throw_buf);

    svcBreak(USERBREAK_PANIC);
    while (true) {}
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
