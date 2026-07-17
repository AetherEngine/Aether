const std = @import("std");

const Io = std.Io;
const http = std.http;
const net = std.Io.net;

const max_file_size = 256 * 1024 * 1024;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, gpa);
    defer args.deinit();
    _ = args.next();

    const root_path = args.next() orelse "zig-out/web";
    const host = args.next() orelse "127.0.0.1";
    const port_text = args.next() orelse "8080";
    const port = try std.fmt.parseInt(u16, port_text, 10);

    var root_dir = try Io.Dir.cwd().openDir(io, root_path, .{});
    defer root_dir.close(io);

    var address = try net.IpAddress.parse(host, port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.debug.print("Serving Aether web build at http://{s}:{d}/\n", .{ host, port });

    while (true) {
        const stream = try server.accept(io);
        handleConnection(io, gpa, root_dir, stream) catch |err| {
            std.debug.print("web connection error: {s}\n", .{@errorName(err)});
        };
    }
}

fn handleConnection(io: Io, gpa: std.mem.Allocator, root_dir: Io.Dir, stream: net.Stream) !void {
    defer {
        var s = stream;
        s.close(io);
    }

    var send_buffer: [4096]u8 = undefined;
    var recv_buffer: [4096]u8 = undefined;
    var connection_reader = stream.reader(io, &recv_buffer);
    var connection_writer = stream.writer(io, &send_buffer);
    var server: http.Server = .init(&connection_reader.interface, &connection_writer.interface);

    while (true) {
        var request = server.receiveHead() catch |err| switch (err) {
            error.HttpConnectionClosing => return,
            else => return err,
        };
        try serveRequest(io, gpa, root_dir, &request);
    }
}

fn serveRequest(io: Io, gpa: std.mem.Allocator, root_dir: Io.Dir, request: *http.Server.Request) !void {
    const path = sanitizeTarget(request.head.target) orelse {
        try respondText(request, .bad_request, "bad request");
        return;
    };

    const file_contents = root_dir.readFileAlloc(io, path, gpa, .limited(max_file_size)) catch |err| switch (err) {
        error.FileNotFound => {
            try respondText(request, .not_found, "not found");
            return;
        },
        else => return err,
    };
    defer gpa.free(file_contents);

    const content_type = contentType(path);
    const headers = commonHeaders(content_type);
    try request.respond(file_contents, .{
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

fn respondText(request: *http.Server.Request, status: http.Status, text: []const u8) !void {
    const headers = commonHeaders("text/plain; charset=utf-8");
    try request.respond(text, .{
        .status = status,
        .keep_alive = false,
        .extra_headers = &headers,
    });
}

fn sanitizeTarget(target: []const u8) ?[]const u8 {
    const no_query = if (std.mem.indexOfScalar(u8, target, '?')) |i| target[0..i] else target;
    if (no_query.len == 0 or no_query[0] != '/') return null;
    const path = if (std.mem.eql(u8, no_query, "/")) "index.html" else no_query[1..];
    if (path.len == 0) return null;
    if (std.mem.indexOf(u8, path, "..") != null) return null;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    return path;
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".js")) return "text/javascript; charset=utf-8";
    if (std.mem.endsWith(u8, path, ".wasm")) return "application/wasm";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".wav")) return "audio/wav";
    if (std.mem.endsWith(u8, path, ".manifest")) return "text/plain; charset=utf-8";
    return "application/octet-stream";
}

fn commonHeaders(content_type: []const u8) [6]http.Header {
    return .{
        .{ .name = "Content-Type", .value = content_type },
        .{ .name = "Content-Security-Policy", .value = "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; connect-src 'self'; img-src 'self' data:; media-src 'self'; style-src 'self' 'unsafe-inline'" },
        .{ .name = "Cross-Origin-Opener-Policy", .value = "same-origin" },
        .{ .name = "Cross-Origin-Embedder-Policy", .value = "require-corp" },
        .{ .name = "Cross-Origin-Resource-Policy", .value = "same-origin" },
        .{ .name = "Cache-Control", .value = "no-store" },
    };
}
