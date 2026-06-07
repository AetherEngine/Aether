//! Zitrus PICA200 shader
//!
//! A simple shader format which omits the need for positional reads and has an overall simpler structure.
//! It omits numerous things that are not used or cannot be used by zitrus.
//!
//! Even if things are tightly packed, all sections are aligned to 32-bits.

pub const magic = "ZPSH";

pub const Header = extern struct {
    pub const Shader = packed struct(u32) {
        entrypoints: u12,
        instructions_minus_one: u12,
        descriptors: u8,

        pub fn init(entrypoints: usize, instructions_size: usize, descriptors: usize) Shader {
            return .{
                .entrypoints = @intCast(entrypoints),
                .instructions_minus_one = @intCast(instructions_size - 1),
                .descriptors = @intCast(descriptors),
            };
        }

        pub fn instructions(size: Shader) usize {
            return @as(usize, size.instructions_minus_one) + 1;
        }
    };

    pub const Flags = packed struct(u8) { _: u8 = 0 };

    magic: [magic.len]u8 = magic.*,
    shader: Shader,
    /// In `u32`s
    entry_string_table_size: u16,
    flags: Flags = .{},
    /// In `u32`s
    header_size: u8 = @divExact(@sizeOf(Header), @sizeOf(u32)),
    /// A xxHash32 hash of instructions and operand descriptors, in the described order.
    /// Seed is 67
    code_hash: u32,

    pub const CheckError = error{ NotZpsh, InvalidZpsh };

    pub fn check(hdr: Header) CheckError!void {
        if (!std.mem.eql(u8, &hdr.magic, magic)) return error.NotZpsh;
    }
};

pub const EntrypointHeader = extern struct {
    pub const Flags = packed struct(u16) {
        _: u16 = 0,
    };

    pub const ShaderInfo = packed struct(u16) {
        pub const vertex: ShaderInfo = .{ .type = .vertex };
        pub const Type = enum(u2) { vertex, geometry_point, geometry_variable, geometry_fixed };

        pub const Geometry = packed union(u14) {
            pub const empty: Geometry = .{ .point = std.mem.zeroes(Geometry.Point) };

            pub const Point = packed struct(u14) {
                inputs_minus_one: u4,
                _: u10 = 0,
            };

            pub const Variable = packed struct(u14) {
                full_vertices: u5,
                _: u9 = 0,
            };

            pub const Fixed = packed struct(u14) {
                vertices_minus_one: u4,
                uniform_start: FloatingRegister,
                _: u3 = 0,
            };

            point: Point,
            fixed: Fixed,
            variable: Variable,

            pub fn initPoint(inputs: u5) Geometry {
                return .{ .point = .{ .inputs_minus_one = @intCast(inputs - 1) } };
            }

            pub fn initVariable(full_vertices: u5) Geometry {
                return .{ .variable = .{ .full_vertices = full_vertices } };
            }

            pub fn initFixed(vertices: u5, uniform_start: FloatingRegister) Geometry {
                return .{ .fixed = .{ .vertices_minus_one = @intCast(vertices - 1), .uniform_start = uniform_start } };
            }
        };

        type: Type,
        geometry: Geometry = .empty,
    };

    pub const BooleanConstantMask = packed struct(u16) {
        // zig fmt: off
        b0: bool, b1: bool, b2: bool, b3: bool, b4: bool, b5: bool, b6: bool, b7: bool,
        b8: bool, b9: bool, b10: bool, b11: bool, b12: bool, b13: bool, b14: bool, b15: bool,
        // zig fmt: on

        pub fn fromSet(set: std.EnumSet(BooleanRegister)) BooleanConstantMask {
            var mask: BooleanConstantMask = std.mem.zeroes(BooleanConstantMask);

            for (std.enums.values(BooleanRegister)) |b| {
                std.mem.writePackedInt(u1, std.mem.asBytes(&mask), @intFromEnum(b), @intFromBool(set.contains(b)), .little);
            }

            return mask;
        }

        pub fn toSet(mask: BooleanConstantMask) std.EnumSet(BooleanRegister) {
            var set: std.EnumSet(BooleanRegister) = .initEmpty();

            for (std.enums.values(BooleanRegister)) |b| {
                set.setPresent(b, std.mem.readPackedInt(u1, std.mem.asBytes(&mask), @intFromEnum(b), .little) != 0);
            }

            return set;
        }
    };

    pub const IntegerConstantMask = packed struct(u16) {
        // zig fmt: off
        i0: bool, i1: bool,
        i2: bool, i3: bool,
        // zig fmt: on
        _: u12,

        pub fn fromSet(set: std.EnumSet(IntegerRegister)) IntegerConstantMask {
            var mask: IntegerConstantMask = std.mem.zeroes(IntegerConstantMask);

            for (std.enums.values(IntegerRegister)) |i| {
                std.mem.writePackedInt(u1, std.mem.asBytes(&mask), @intFromEnum(i), @intFromBool(set.contains(i)), .little);
            }

            return mask;
        }

        pub fn toSet(mask: IntegerConstantMask) std.EnumSet(IntegerRegister) {
            var set: std.EnumSet(IntegerRegister) = .initEmpty();

            for (std.enums.values(IntegerRegister)) |i| {
                set.setPresent(i, std.mem.readPackedInt(u1, std.mem.asBytes(&mask), @intFromEnum(i), .little) != 0);
            }

            return set;
        }
    };

    pub const FloatingConstantMask = extern struct {
        // zig fmt: off
        pub const Low = packed struct(u32) {
            f0: bool, f1: bool, f2: bool, f3: bool, f4: bool, f5: bool, f6: bool, f7: bool,
            f8: bool, f9: bool, f10: bool, f11: bool, f12: bool, f13: bool, f14: bool, f15: bool,
            f16: bool, f17: bool, f18: bool, f19: bool, f20: bool, f21: bool, f22: bool, f23: bool,
            f24: bool, f25: bool, f26: bool, f27: bool, f28: bool, f29: bool, f30: bool, f31: bool, 
        };

        pub const Mid = packed struct(u32) {
            f32: bool, f33: bool, f34: bool, f35: bool, f36: bool, f37: bool, f38: bool, f39: bool,
            f40: bool, f41: bool, f42: bool, f43: bool, f44: bool, f45: bool, f46: bool, f47: bool,
            f48: bool, f49: bool, f50: bool, f51: bool, f52: bool, f53: bool, f54: bool, f55: bool,
            f56: bool, f57: bool, f58: bool, f59: bool, f60: bool, f61: bool, f62: bool, f63: bool, 
        };

        pub const High = packed struct(u32) {
            f64: bool, f65: bool, f66: bool, f67: bool, f68: bool, f69: bool, f70: bool, f71: bool,
            f72: bool, f73: bool, f74: bool, f75: bool, f76: bool, f77: bool, f78: bool, f79: bool,
            f80: bool, f81: bool, f82: bool, f83: bool, f84: bool, f85: bool, f86: bool, f87: bool,
            f88: bool, f89: bool, f90: bool, f91: bool, f92: bool, f93: bool, f94: bool, f95: bool,
        };
        // zig fmt: on

        low: Low,
        mid: Mid,
        high: High,

        pub fn fromSet(set: std.EnumSet(FloatingRegister)) FloatingConstantMask {
            var mask: FloatingConstantMask = std.mem.zeroes(FloatingConstantMask);

            for (std.enums.values(FloatingRegister)) |f| {
                std.mem.writePackedInt(u1, std.mem.asBytes(&mask), @intFromEnum(f), @intFromBool(set.contains(f)), .little);
            }

            return mask;
        }

        pub fn toSet(mask: FloatingConstantMask) std.EnumSet(FloatingRegister) {
            var set: std.EnumSet(FloatingRegister) = .initEmpty();

            for (std.enums.values(FloatingRegister)) |f| {
                set.setPresent(f, std.mem.readPackedInt(u1, std.mem.asBytes(&mask), @intFromEnum(f), .little) != 0);
            }

            return set;
        }
    };

    pub const OutputMask = packed struct(u32) {
        // zig fmt: off
        o0: bool, o1: bool, o2: bool, o3: bool, o4: bool, o5: bool, o6: bool, o7: bool,
        o8: bool, o9: bool, o10: bool, o11: bool, o12: bool, o13: bool, o14: bool, o15: bool,
        _: u16 = 0,
        // zig fmt: on

        pub fn fromSet(set: std.EnumSet(OutputRegister)) OutputMask {
            var mask: OutputMask = std.mem.zeroes(OutputMask);

            for (std.enums.values(OutputRegister)) |o| {
                std.mem.writePackedInt(u1, std.mem.asBytes(&mask), @intFromEnum(o), @intFromBool(set.contains(o)), .little);
            }

            return mask;
        }

        pub fn toSet(mask: OutputMask) std.EnumSet(OutputRegister) {
            var set: std.EnumSet(OutputRegister) = .initEmpty();

            for (std.enums.values(OutputRegister)) |o| {
                set.setPresent(o, std.mem.readPackedInt(u1, std.mem.asBytes(&mask), @intFromEnum(o), .little) != 0);
            }

            return set;
        }
    };

    name_string_offset: u32,
    instruction_offset: u16,
    info: ShaderInfo,
    flags: Flags,
    header_size: u16 = @divExact(@sizeOf(EntrypointHeader), @sizeOf(u32)),

    // NOTE: Constants are sorted, that is, e.g: f0 = true, f1 = false, f2 = true then in memory there will be two floating constant entries that correspond to f0 and f2. Same for integers and same for outputs.
    boolean_constant_mask: BooleanConstantMask,
    integer_constant_mask: IntegerConstantMask,
    floating_constant_mask: FloatingConstantMask,
    output_mask: OutputMask,
};

pub const Parsed = struct {
    code_hash: u32,
    instructions: []const shader.encoding.Instruction,
    operand_descriptors: []const shader.encoding.OperandDescriptor,
    string_table: []const u8,
    entrypoint_offsets: []const u8,
    entrypoint_data: []const u8,
    entrypoints: usize,

    pub fn initBuffer(buffer: []const u8) Header.CheckError!Parsed {
        const header = try checkedSlice(buffer, 0, @sizeOf(Header));
        if (!std.mem.eql(u8, header[0..magic.len], magic)) return error.NotZpsh;

        const shader_word = try readLittle(u32, header, 4);
        const entrypoints: usize = @intCast(shader_word & 0xfff);
        const instructions_minus_one: u16 = @intCast((shader_word >> 12) & 0xfff);
        const descriptors: u8 = @intCast(shader_word >> 24);
        const instructions_count = @as(usize, instructions_minus_one) + 1;
        const entry_string_table_size = try readLittle(u16, header, 8);
        const header_size_words = try readLittle(u8, header, 11);
        const code_hash = try readLittle(u32, header, 12);

        const header_size = try checkedMul(@as(usize, header_size_words), @sizeOf(u32));
        if (header_size < @sizeOf(Header)) return error.InvalidZpsh;
        const entrypoint_offsets_start = header_size;
        const entrypoint_offsets_size = try checkedMul(@as(usize, entrypoints), @sizeOf(u32));
        const code_start = try checkedAdd(entrypoint_offsets_start, entrypoint_offsets_size);
        const code_size = try checkedMul(@sizeOf(shader.encoding.Instruction), instructions_count);
        const operands_start = try checkedAdd(code_start, code_size);
        const operands_size = try checkedMul(@sizeOf(shader.encoding.OperandDescriptor), @as(usize, descriptors));
        const string_table_start = try checkedAdd(operands_start, operands_size);
        const string_table_size = try checkedMul(@as(usize, entry_string_table_size), @sizeOf(u32));
        const entrypoints_start = try checkedAdd(string_table_start, string_table_size);

        if (entrypoints_start > buffer.len) return error.InvalidZpsh;

        return .{
            .code_hash = code_hash,
            .instructions = @alignCast(std.mem.bytesAsSlice(pica.shader.encoding.Instruction, try checkedSlice(buffer, code_start, code_size))),
            .operand_descriptors = @alignCast(std.mem.bytesAsSlice(pica.shader.encoding.OperandDescriptor, try checkedSlice(buffer, operands_start, operands_size))),
            .string_table = try checkedSlice(buffer, string_table_start, string_table_size),
            .entrypoint_offsets = try checkedSlice(buffer, entrypoint_offsets_start, entrypoint_offsets_size),
            .entrypoint_data = buffer[entrypoints_start..],
            .entrypoints = entrypoints,
        };
    }

    pub fn iterator(parsed: *const Parsed) EntrypointIterator {
        return .{
            .parsed = parsed,
            .offset_cursor = 0,
        };
    }

    // TODO: This assumes a proper ZPSH (as we're the only ones who currently use them we're allowed to not care :p)
    pub const EntrypointIterator = struct {
        pub const Entry = struct {
            info: EntrypointHeader.ShaderInfo,
            offset: u16,

            name: [:0]const u8,
            boolean_constant_set: std.enums.EnumSet(BooleanRegister),
            integer_constant_set: std.enums.EnumSet(IntegerRegister),
            floating_constant_set: std.enums.EnumSet(FloatingRegister),
            output_set: std.enums.EnumSet(OutputRegister),

            integer_constants: []const [4]u8,
            floating_constants: []const pica.F7_16x4,
            output_map: []const pica.OutputMap,
        };

        parsed: *const Parsed,
        offset_cursor: usize,

        pub fn next(it: *EntrypointIterator) Header.CheckError!?Entry {
            if (it.offset_cursor >= it.parsed.entrypoint_offsets.len) return null;

            const offset = try readLittle(u32, it.parsed.entrypoint_offsets, it.offset_cursor);
            it.offset_cursor +%= @sizeOf(u32);

            const entry_offset: usize = @intCast(offset);
            if (entry_offset > it.parsed.entrypoint_data.len) return error.InvalidZpsh;
            const entry_start = it.parsed.entrypoint_data[entry_offset..];
            _ = try checkedSlice(entry_start, 0, @sizeOf(EntrypointHeader));

            const name_string_offset = try readLittle(u32, entry_start, 0);
            const instruction_offset = try readLittle(u16, entry_start, 4);
            const info: EntrypointHeader.ShaderInfo = @bitCast(try readLittle(u16, entry_start, 6));
            const boolean_constant_set = enumSetFromMask(BooleanRegister, u16, try readLittle(u16, entry_start, 12));
            const integer_constant_set = enumSetFromMask(IntegerRegister, u16, try readLittle(u16, entry_start, 14));
            const floating_constant_set = floatingSetFromMask(
                try readLittle(u32, entry_start, 16),
                try readLittle(u32, entry_start, 20),
                try readLittle(u32, entry_start, 24),
            );
            const output_map_set = enumSetFromMask(OutputRegister, u32, try readLittle(u32, entry_start, 28));

            const integer_constants_byte_size = try checkedMul(integer_constant_set.count(), @sizeOf([4]u8));
            const floating_constants_byte_size = try checkedMul(floating_constant_set.count(), @sizeOf(pica.F7_16x4));
            const output_map_byte_size = try checkedMul(output_map_set.count(), @sizeOf(pica.OutputMap));
            const integer_constants_start = @sizeOf(EntrypointHeader);
            const floating_constants_start = try checkedAdd(integer_constants_start, integer_constants_byte_size);
            const output_map_start = try checkedAdd(floating_constants_start, floating_constants_byte_size);

            if (instruction_offset > std.math.maxInt(u12)) return error.InvalidZpsh;
            if (name_string_offset > it.parsed.string_table.len) return error.InvalidZpsh;
            const name_tail = it.parsed.string_table[name_string_offset..];
            const name_end = std.mem.indexOfScalar(u8, name_tail, 0) orelse return error.InvalidZpsh;

            return .{
                .info = info,
                .offset = @intCast(instruction_offset),

                .name = name_tail[0..name_end :0],
                .boolean_constant_set = boolean_constant_set,
                .integer_constant_set = integer_constant_set,
                .floating_constant_set = floating_constant_set,
                .output_set = output_map_set,

                .integer_constants = @alignCast(std.mem.bytesAsSlice([4]u8, try checkedSlice(entry_start, integer_constants_start, integer_constants_byte_size))),
                .floating_constants = @alignCast(std.mem.bytesAsSlice(pica.F7_16x4, try checkedSlice(entry_start, floating_constants_start, floating_constants_byte_size))),
                .output_map = @alignCast(std.mem.bytesAsSlice(pica.OutputMap, try checkedSlice(entry_start, output_map_start, output_map_byte_size))),
            };
        }
    };
};

fn checkedAdd(a: usize, b: usize) Header.CheckError!usize {
    if (a > std.math.maxInt(usize) - b) return error.InvalidZpsh;
    return a + b;
}

fn checkedMul(a: usize, b: usize) Header.CheckError!usize {
    if (b != 0 and a > std.math.maxInt(usize) / b) return error.InvalidZpsh;
    return a * b;
}

fn checkedSlice(buffer: []const u8, start: usize, len: usize) Header.CheckError![]const u8 {
    const end = try checkedAdd(start, len);
    if (end > buffer.len) return error.InvalidZpsh;
    return buffer[start..end];
}

fn readLittle(comptime T: type, buffer: []const u8, offset: usize) Header.CheckError!T {
    const bytes = try checkedSlice(buffer, offset, @sizeOf(T));
    return std.mem.readInt(T, bytes[0..@sizeOf(T)], .little);
}

fn enumSetFromMask(comptime E: type, comptime T: type, mask: T) std.EnumSet(E) {
    var set: std.EnumSet(E) = .initEmpty();
    for (std.enums.values(E)) |value| {
        const bit: std.math.Log2Int(T) = @intCast(@intFromEnum(value));
        set.setPresent(value, ((mask >> bit) & 1) != 0);
    }
    return set;
}

fn floatingSetFromMask(low: u32, mid: u32, high: u32) std.EnumSet(FloatingRegister) {
    var set: std.EnumSet(FloatingRegister) = .initEmpty();
    for (std.enums.values(FloatingRegister)) |value| {
        const index = @intFromEnum(value);
        const word = switch (index / 32) {
            0 => low,
            1 => mid,
            2 => high,
            else => unreachable,
        };
        const bit: u5 = @intCast(index & 31);
        set.setPresent(value, ((word >> bit) & 1) != 0);
    }
    return set;
}

comptime {
    std.debug.assert(std.mem.isAligned(@sizeOf(Header), @sizeOf(u32)));
    std.debug.assert(std.mem.isAligned(@sizeOf(EntrypointHeader), @sizeOf(u32)));
}

const builtin = @import("builtin");
const std = @import("std");
const zitrus = @import("zitrus");
const pica = zitrus.hardware.pica;
const shader = pica.shader;

const BooleanRegister = shader.register.Integral.Boolean;
const IntegerRegister = shader.register.Integral.Integer;
const FloatingRegister = shader.register.Source.Constant;
const OutputRegister = shader.register.Destination.Output;
