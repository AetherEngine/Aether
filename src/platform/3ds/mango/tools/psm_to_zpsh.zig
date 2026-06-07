pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 3) {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        try stderr.interface.writeAll("usage: psm_to_zpsh <input.psm> <output.psh>\n");
        try stderr.interface.flush();
        return 1;
    }

    const cwd = std.Io.Dir.cwd();
    const input = cwd.openFile(io, args[1], .{ .mode = .read_only }) catch |err| {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        try stderr.interface.print("could not open {s}: {t}\n", .{ args[1], err });
        try stderr.interface.flush();
        return 1;
    };
    defer input.close(io);

    var input_reader = input.readerStreaming(io, &.{});
    var source: std.ArrayList(u8) = .empty;
    try input_reader.interface.appendRemaining(arena, &source, .unlimited);
    const source_z = try source.toOwnedSliceSentinel(arena, 0);

    var assembled = Assembler.Assembled.assemble(arena, source_z) catch |err| {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        try stderr.interface.print("shader assembly failed: {t}\n", .{err});
        try stderr.interface.flush();
        return 1;
    };
    defer assembled.deinit(arena);

    if (assembled.errors.len != 0) {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        for (assembled.errors) |err| {
            const token = assembled.tokenSlice(err.tok_i);
            try stderr.interface.print("{s}: assembler error {t} near '{s}'\n", .{ args[1], err.tag, token });
        }
        try stderr.interface.flush();
        return 1;
    }

    const output = cwd.createFile(io, args[2], .{ .truncate = true }) catch |err| {
        var stderr = std.Io.File.stderr().writer(io, &.{});
        try stderr.interface.print("could not create {s}: {t}\n", .{ args[2], err });
        try stderr.interface.flush();
        return 1;
    };
    defer output.close(io);

    var out_buf: [4096]u8 = undefined;
    var output_writer = output.writer(io, &out_buf);
    try writeZpsh(arena, &output_writer.interface, &assembled);
    try output_writer.interface.flush();
    return 0;
}

fn writeZpsh(gpa: std.mem.Allocator, out: *std.Io.Writer, assembled: *const Assembler.Assembled) !void {
    if (assembled.encoded.instructions.items.len == 0) return error.EmptyShader;
    if (assembled.encoded.instructions.items.len > std.math.maxInt(u12)) return error.ShaderTooLarge;
    if (assembled.entrypoints.count() > std.math.maxInt(u12)) return error.TooManyEntrypoints;

    const encoded = &assembled.encoded;

    var padded_strings_size: usize = 0;
    var entry_it = assembled.entrypoints.iterator();
    while (entry_it.next()) |entrypoint| {
        padded_strings_size += entrypoint.key_ptr.*.len + 1;
    }
    padded_strings_size = std.mem.alignForward(usize, padded_strings_size, @sizeOf(u32));

    var string_table: std.ArrayList(u8) = try .initCapacity(gpa, padded_strings_size);
    defer string_table.deinit(gpa);

    var entrypoint_offsets: std.ArrayList(u32) = try .initCapacity(gpa, assembled.entrypoints.count());
    defer entrypoint_offsets.deinit(gpa);

    var current_entrypoint_offset: u32 = 0;
    entry_it.reset();
    while (entry_it.next()) |entrypoint| {
        const info = entrypoint.value_ptr.*;
        string_table.appendSliceAssumeCapacity(entrypoint.key_ptr.*);
        string_table.appendAssumeCapacity(0);
        entrypoint_offsets.appendAssumeCapacity(current_entrypoint_offset);
        current_entrypoint_offset += @intCast(@sizeOf(zpsh.EntrypointHeader) +
            info.constants.int.count() * @sizeOf([4]i8) +
            info.constants.float.count() * @sizeOf(pica.F7_16x4) +
            info.outputs.count() * @sizeOf(pica.OutputMap));
    }
    string_table.appendNTimesAssumeCapacity(0, padded_strings_size - string_table.items.len);

    var code_hasher: std.hash.XxHash32 = .init(67);
    code_hasher.update(@ptrCast(encoded.instructions.items));
    code_hasher.update(@ptrCast(encoded.constDescriptorSlice()));

    try out.writeStruct(zpsh.Header{
        .shader = .init(assembled.entrypoints.count(), encoded.instructions.items.len, encoded.allocated_descriptors),
        .entry_string_table_size = @intCast(@divExact(padded_strings_size, @sizeOf(u32))),
        .code_hash = code_hasher.final(),
    }, .little);

    try out.writeSliceEndian(u32, entrypoint_offsets.items, .little);
    try out.writeSliceEndian(u32, @ptrCast(encoded.instructions.items), .little);
    try out.writeSliceEndian(u32, @ptrCast(encoded.constDescriptorSlice()), .little);
    try out.writeAll(string_table.items);

    var current_string_offset: u32 = 0;
    entry_it.reset();
    while (entry_it.next()) |entrypoint| {
        const info = entrypoint.value_ptr;
        try out.writeStruct(zpsh.EntrypointHeader{
            .name_string_offset = @intCast(current_string_offset),
            .instruction_offset = info.offset,
            .info = switch (info.info) {
                .vertex => .vertex,
                .geometry => |g| switch (g) {
                    .point => |p| .{
                        .type = .geometry_point,
                        .geometry = .initPoint(p.inputs),
                    },
                    .variable => |v| .{
                        .type = .geometry_variable,
                        .geometry = .initVariable(v.full_vertices),
                    },
                    .fixed => |f| .{
                        .type = .geometry_fixed,
                        .geometry = .initFixed(f.vertices, f.uniform_start),
                    },
                },
            },
            .flags = .{},
            .boolean_constant_mask = .fromSet(.{ .bits = info.constants.bool.bits }),
            .integer_constant_mask = .fromSet(.{ .bits = info.constants.int.bits }),
            .floating_constant_mask = .fromSet(.{ .bits = info.constants.float.bits }),
            .output_mask = .fromSet(.{ .bits = info.outputs.bits }),
        }, .little);

        current_string_offset += @intCast(entrypoint.key_ptr.len + 1);

        var int_it = info.constants.int.iterator();
        while (int_it.next()) |entry| try out.writeAll(entry.value);

        var float_it = info.constants.float.iterator();
        while (float_it.next()) |entry| try out.writeStruct(entry.value.*, .little);

        var output_it = info.outputs.iterator();
        while (output_it.next()) |entry| try out.writeStruct(entry.value.*, .little);
    }
}

const std = @import("std");
const zitrus = @import("zitrus");
const pica = zitrus.hardware.pica;
const zpsh = zitrus.fmt.zpsh;
const Assembler = pica.shader.as.Assembler;

