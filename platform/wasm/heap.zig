//! Browser heap. std's wasm_allocator rounds every big allocation up to a
//! power of two of 64 KiB pages and only reuses a freed block for the same
//! size class, so a 129 MiB request grows linear memory by 256 MiB. Large
//! blocks here take exactly the pages they need from a coalescing free list.
const std = @import("std");
const assert = std.debug.assert;
const Alignment = std.mem.Alignment;

const small = std.heap.wasm_allocator;
const page_size = std.wasm.page_size;
// Below this the small allocator's rounding wastes at most one block's size.
const large_threshold = 256 * 1024;

/// Header written into the first page of each free span; spans are kept
/// sorted by address so neighbours coalesce on free.
const Span = struct {
    next: ?*Span,
    pages: usize,

    // Page indices rather than byte addresses: the top page ends at 4 GiB,
    // which overflows a wasm32 usize.
    fn first_page(self: *const Span) usize {
        return @intFromPtr(self) / page_size;
    }

    fn end_page(self: *const Span) usize {
        return self.first_page() + self.pages;
    }
};

var free_spans: ?*Span = null;

pub const allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    },
};

fn is_large(len: usize) bool {
    return len >= large_threshold;
}

fn pages_for(len: usize) usize {
    return std.math.divCeil(usize, len, page_size) catch unreachable;
}

fn grow(pages: usize) ?usize {
    const index = @wasmMemoryGrow(0, pages);
    if (index < 0) return null;
    return @intCast(index);
}

/// Removes `pages` from the front of `span`, which `link` points to.
fn carve(link: *?*Span, span: *Span, pages: usize) [*]u8 {
    assert(span.pages >= pages);
    const base: [*]u8 = @ptrCast(span);
    if (span.pages == pages) {
        link.* = span.next;
    } else {
        const rest: *Span = @ptrCast(@alignCast(base + pages * page_size));
        rest.* = .{ .next = span.next, .pages = span.pages - pages };
        link.* = rest;
    }
    return base;
}

fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    if (!is_large(len)) return small.rawAlloc(len, alignment, ret_addr);
    if (alignment.toByteUnits() > page_size) return null;

    const pages = pages_for(len);
    var link = &free_spans;
    var last_link: ?*?*Span = null;
    while (link.*) |span| {
        if (span.pages >= pages) return carve(link, span, pages);
        last_link = link;
        link = &span.next;
    }

    if (last_link) |ll| {
        const last = ll.*.?;
        if (last.end_page() == @wasmMemorySize(0)) {
            const start = grow(pages - last.pages) orelse return null;
            assert(start == last.end_page());
            last.pages = pages;
            return carve(ll, last, pages);
        }
    }

    const start = grow(pages) orelse return null;
    return @ptrFromInt(start * page_size);
}

fn release(base: [*]u8, pages: usize) void {
    var link = &free_spans;
    var prev: ?*Span = null;
    while (link.*) |span| {
        if (@intFromPtr(span) > @intFromPtr(base)) break;
        prev = span;
        link = &span.next;
    }

    const node: *Span = @ptrCast(@alignCast(base));
    node.* = .{ .next = link.*, .pages = pages };
    if (node.next) |next| if (node.end_page() == next.first_page()) {
        node.pages += next.pages;
        node.next = next.next;
    };
    if (prev) |p| if (p.end_page() == node.first_page()) {
        p.pages += node.pages;
        p.next = node.next;
        return;
    };
    link.* = node;
}

fn resize(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
    _ = ctx;
    // Each side must stay with the allocator that owns it, since free
    // dispatches on length alone.
    if (is_large(buf.len) != is_large(new_len)) return false;
    if (!is_large(buf.len)) return small.rawResize(buf, alignment, new_len, ret_addr);

    const old_pages = pages_for(buf.len);
    const new_pages = pages_for(new_len);
    if (new_pages == old_pages) return true;
    if (new_pages < old_pages) {
        release(buf.ptr + new_pages * page_size, old_pages - new_pages);
        return true;
    }

    const need = new_pages - old_pages;
    const end_page = @intFromPtr(buf.ptr) / page_size + old_pages;
    var link = &free_spans;
    while (link.*) |span| : (link = &span.next) {
        if (span.first_page() < end_page) continue;
        if (span.first_page() > end_page or span.pages < need) return false;
        _ = carve(link, span, need);
        return true;
    }
    if (end_page != @wasmMemorySize(0)) return false;
    return grow(need) != null;
}

fn remap(ctx: *anyopaque, buf: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
    return if (resize(ctx, buf, alignment, new_len, ret_addr)) buf.ptr else null;
}

fn free(ctx: *anyopaque, buf: []u8, alignment: Alignment, ret_addr: usize) void {
    _ = ctx;
    if (!is_large(buf.len)) return small.rawFree(buf, alignment, ret_addr);
    release(buf.ptr, pages_for(buf.len));
}
