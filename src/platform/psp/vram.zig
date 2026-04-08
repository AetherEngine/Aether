const std = @import("std");
const sdk = @import("pspsdk");

const ge = sdk.ge;
const gu_types = sdk.gu.types;

const VRAM_ALIGNMENT: usize = 16;

var current_offset: usize = 0;

pub const RelativeBuffer = struct {
    ptr: ?*align(16) anyopaque,
    len: usize,
};

pub fn alloc_relative_buffer(stride: u32, height: u32, format: gu_types.GuPixelFormat) RelativeBuffer {
    const resource_offset = std.mem.alignForward(usize, current_offset, VRAM_ALIGNMENT);
    const size_bytes = buffer_size_bytes(stride, height, format);
    const end_offset = std.math.add(usize, resource_offset, size_bytes) catch @panic("VRAM allocation size overflow");
    const edram_size: usize = ge.edram_get_size();

    if (end_offset > edram_size) {
        std.debug.panic("VRAM allocation overflow: offset=0x{x} size=0x{x} end=0x{x} edram=0x{x}", .{
            resource_offset,
            size_bytes,
            end_offset,
            edram_size,
        });
    }

    current_offset = std.mem.alignForward(usize, end_offset, VRAM_ALIGNMENT);
    return .{
        .ptr = @ptrFromInt(resource_offset),
        .len = size_bytes,
    };
}

pub fn alloc_relative(stride: u32, height: u32, format: gu_types.GuPixelFormat) ?*align(16) anyopaque {
    return alloc_relative_buffer(stride, height, format).ptr;
}

pub fn alloc_absolute_slice(stride: u32, height: u32, format: gu_types.GuPixelFormat) []align(16) u8 {
    const buffer = alloc_relative_buffer(stride, height, format);
    const relative_addr: usize = if (buffer.ptr) |ptr| @intFromPtr(ptr) else 0;
    const absolute_ptr: [*]align(16) u8 = @ptrFromInt(relative_addr + @intFromPtr(ge.edram_get_addr()));
    return absolute_ptr[0..buffer.len];
}

pub fn alloc_absolute(stride: u32, height: u32, format: gu_types.GuPixelFormat) ?*align(16) anyopaque {
    return @ptrCast(alloc_absolute_slice(stride, height, format).ptr);
}

fn buffer_size_bytes(stride_elements: u32, height: u32, format: gu_types.GuPixelFormat) usize {
    return (@as(usize, stride_elements) * height * pixel_format_size_bits(format)) / 8;
}

fn pixel_format_size_bits(pixel_format: gu_types.GuPixelFormat) usize {
    return switch (pixel_format) {
        .Psm5650 => 16,
        .Psm5551 => 16,
        .Psm4444 => 16,
        .Psm8888 => 32,
        .PsmT4 => 4,
        .PsmT8 => 8,
        .PsmT16 => 16,
        .PsmT32 => 32,
        .PsmDxt1, .PsmDxt1Ext => 4,
        .PsmDxt3, .PsmDxt3Ext => 8,
        .PsmDxt5, .PsmDxt5Ext => 8,
    };
}
