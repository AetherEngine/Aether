const std = @import("std");

pub fn assert_impl(comptime name: []const u8, comptime Backend: type, comptime Interface: type) void {
    inline for (comptime std.meta.fieldNames(Interface), comptime std.meta.fieldTypes(Interface)) |field_name, Expected| {
        const prefix = name ++ " backend " ++ @typeName(Backend);
        if (!@hasDecl(Backend, field_name)) {
            @compileError(prefix ++ " is missing decl: " ++ field_name);
        }
        const Actual = @TypeOf(@field(Backend, field_name));
        if (Actual != Expected) {
            @compileError(prefix ++ "." ++ field_name ++ " has type " ++
                @typeName(Actual) ++ ", expected " ++ @typeName(Expected));
        }
    }
}
