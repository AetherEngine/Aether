const std = @import("std");

/// The contract every surface backend must satisfy. Surfaces have real
/// instance state (window handle, dimensions, etc.) so methods take a
/// `*Backend` self pointer. This struct is never instantiated — it
/// exists purely to drive `assertImpl` at comptime.
pub fn Interface(comptime Backend: type) type {
    return struct {
        init: fn (*Backend, u32, u32, [:0]const u8, bool, bool, bool) anyerror!void,
        deinit: fn (*Backend) void,
        update: fn (*Backend) bool,
        draw: fn (*Backend) void,
        get_width: fn (*Backend) u32,
        get_height: fn (*Backend) u32,
    };
}

/// Verify at comptime that `Backend` exposes every decl in `Interface`
/// with the exact expected signature.
pub fn assertImpl(comptime Backend: type) void {
    const I = Interface(Backend);
    inline for (std.meta.fields(I)) |f| {
        if (!@hasDecl(Backend, f.name)) {
            @compileError("surface backend " ++ @typeName(Backend) ++ " is missing decl: " ++ f.name);
        }
        const Actual = @TypeOf(@field(Backend, f.name));
        if (Actual != f.type) {
            @compileError("surface backend " ++ @typeName(Backend) ++ "." ++ f.name ++
                " has type " ++ @typeName(Actual) ++ ", expected " ++ @typeName(f.type));
        }
    }
}
