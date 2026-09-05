const std = @import("std");

pub fn assert_impl(comptime name: []const u8, comptime Backend: type, comptime Interface: type) void {
    inline for (std.meta.fields(Interface)) |field| {
        const prefix = name ++ " backend " ++ @typeName(Backend);
        if (!@hasDecl(Backend, field.name)) {
            @compileError(prefix ++ " is missing decl: " ++ field.name);
        }
        const Actual = @TypeOf(@field(Backend, field.name));
        if (Actual != field.type) {
            @compileError(prefix ++ "." ++ field.name ++ " has type " ++
                @typeName(Actual) ++ ", expected " ++ @typeName(field.type));
        }
    }
}
