//! 3DS debug overrides consumed by Zitrus' root.debug hook.

const std = @import("std");
const aether = @import("aether");
const app_root = @import("aether_user_root");

const impl = aether.N3ds.Debug;
pub const Exception = impl.Exception;

pub fn installExceptionHandler() void {
    impl.installExceptionHandler(&handleException);
}

pub fn handleSegfault(addr: ?usize, name: []const u8, opt_ctx: ?std.debug.CpuContextPtr) noreturn {
    if (@hasDecl(app_root, "debug") and @hasDecl(app_root.debug, "handleSegfault")) {
        return app_root.debug.handleSegfault(addr, name, opt_ctx);
    }

    return impl.handleSegfault(addr, name, opt_ctx);
}

fn handleException(info: *const Exception.Info, registers: *const Exception.Registers) callconv(.c) noreturn {
    if (@hasDecl(app_root, "debug") and @hasDecl(app_root.debug, "handleException")) {
        return app_root.debug.handleException(info, registers);
    }

    return impl.handleException(info, registers);
}
