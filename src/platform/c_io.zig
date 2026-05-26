const std = @import("std");
const options = @import("options");

const Io = std.Io;
const Dir = Io.Dir;
const File = Io.File;

const platform_time = switch (options.config.platform) {
    .nintendo_3ds => @import("3ds/time.zig"),
    .nintendo_switch => @import("switch/time.zig"),
    else => @compileError("platform/c_io.zig is only wired for Nintendo targets"),
};
const platform_paths = switch (options.config.platform) {
    .nintendo_3ds => @import("3ds/paths.zig"),
    .nintendo_switch => @import("switch/paths.zig"),
    else => unreachable,
};

const c = struct {
    extern fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
    extern fn close(fd: c_int) c_int;
    extern fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    extern fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
    extern fn lseek(fd: c_int, offset: c_long, whence: c_int) c_long;
    extern fn fsync(fd: c_int) c_int;
    extern fn ftruncate(fd: c_int, length: c_long) c_int;
    extern fn getcwd(buf: [*]u8, size: usize) ?[*:0]u8;
    extern fn chdir(path: [*:0]const u8) c_int;
    extern fn mkdir(path: [*:0]const u8, mode: c_int) c_int;
    extern fn __errno() *c_int;
};

const max_path_bytes = 1024;

const O_RDONLY: c_int = 0;
const O_WRONLY: c_int = 1;
const O_RDWR: c_int = 2;
const O_CREAT: c_int = 0x0200;
const O_TRUNC: c_int = 0x0400;
const O_EXCL: c_int = 0x0800;

const SEEK_SET: c_int = 0;
const SEEK_CUR: c_int = 1;
const SEEK_END: c_int = 2;

var read_fd: c_int = -1;
var write_fd: c_int = -1;
var stderr_writer: File.Writer = undefined;
var stderr_writer_initialized = false;
var empty_stderr_buffer: [0]u8 = .{};
var resource_root_buffer: [max_path_bytes:0]u8 = @splat(0);
var data_root_buffer: [max_path_bytes:0]u8 = @splat(0);
var resource_root_len: usize = 0;
var data_root_len: usize = 0;

const vtable: Io.VTable = blk: {
    var v = Io.failing.vtable.*;
    v.crashHandler = crashHandler;
    v.async = Io.noAsync;
    v.groupAsync = Io.noGroupAsync;
    v.recancel = recancel;
    v.swapCancelProtection = swapCancelProtection;
    v.checkCancel = checkCancel;
    v.operate = operate;
    v.dirCreateFile = dirCreateFile;
    v.dirOpenFile = dirOpenFile;
    v.fileStat = fileStat;
    v.fileLength = fileLength;
    v.fileClose = fileClose;
    v.fileWritePositional = fileWritePositional;
    v.fileReadPositional = fileReadPositional;
    v.fileSeekBy = fileSeekBy;
    v.fileSeekTo = fileSeekTo;
    v.fileSync = fileSync;
    v.fileIsTty = fileIsTty;
    v.fileEnableAnsiEscapeCodes = fileEnableAnsiEscapeCodes;
    v.fileSupportsAnsiEscapeCodes = fileSupportsAnsiEscapeCodes;
    v.fileSetLength = fileSetLength;
    v.lockStderr = lockStderr;
    v.tryLockStderr = tryLockStderr;
    v.unlockStderr = unlockStderr;
    v.processCurrentPath = processCurrentPath;
    v.processSetCurrentPath = processSetCurrentPath;
    v.now = now;
    v.clockResolution = clockResolution;
    v.sleep = sleep;
    v.random = random;
    break :blk v;
};

pub fn io() Io {
    return .{ .userdata = null, .vtable = &vtable };
}

pub fn initAppDirs(app_name: []const u8) Dir.CreateDirPathOpenError!void {
    if (platform_paths.mountResources()) {
        setResourceRoot("romfs:/") catch return error.NameTooLong;
    } else {
        setResourceRoot("") catch unreachable;
    }

    var data_buffer: [max_path_bytes]u8 = undefined;
    const data_root = platform_paths.dataRoot(&data_buffer, app_name) catch return error.NameTooLong;
    try setDataRoot(data_root);
    try ensureDirPath(data_root);
}

pub fn useCwdDirs() void {
    setResourceRoot("") catch unreachable;
    setDataRoot("") catch unreachable;
}

fn crashHandler(_: ?*anyopaque) void {}

fn recancel(_: ?*anyopaque) void {}

fn swapCancelProtection(_: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = new;
    return .unblocked;
}

fn checkCancel(_: ?*anyopaque) Io.Cancelable!void {}

fn operate(_: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => |op| .{ .file_read_streaming = fileReadStreaming(op.file, op.data) },
        .file_write_streaming => |op| .{ .file_write_streaming = fileWriteStreaming(op.file, op.header, op.data, op.splat) },
        .device_io_control => unsupported("device_io_control"),
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
    };
}

fn dirOpenFile(_: ?*anyopaque, _: Dir, sub_path: []const u8, flags: Dir.OpenFileOptions) File.OpenError!File {
    if (flags.lock != .none or flags.path_only or flags.allow_ctty or flags.resolve_beneath)
        unsupported("dirOpenFile option");
    if (!flags.allow_directory or !flags.follow_symlinks)
        unsupported("dirOpenFile path policy");
    const role: FileRole = switch (flags.mode) {
        .read_only => .read,
        .write_only => .write,
        .read_write => unsupported("read-write file open on handle-less Nintendo target"),
    };

    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const open_flags: c_int = switch (flags.mode) {
        .read_only => O_RDONLY,
        .write_only => O_WRONLY,
        .read_write => O_RDWR,
    };
    const path = try rootedPath(&path_buffer, sub_path, if (flags.mode == .read_only) resourceRoot() else dataRoot());
    var fd = c.open(path.ptr, open_flags, @as(c_int, 0));
    if (fd < 0 and flags.mode == .read_only and data_root_len > 0) {
        const first_errno = errno();
        if (first_errno != 2) return openError(first_errno);
        const fallback_path = try rootedPath(&path_buffer, sub_path, dataRoot());
        fd = c.open(fallback_path.ptr, open_flags, @as(c_int, 0));
    }
    if (fd < 0) return openError(errno());
    errdefer _ = c.close(fd);
    return registerFile(fd, role);
}

fn dirCreateFile(_: ?*anyopaque, _: Dir, sub_path: []const u8, flags: Dir.CreateFileOptions) File.OpenError!File {
    if (flags.lock != .none or flags.resolve_beneath) unsupported("dirCreateFile option");
    if (flags.read) unsupported("readable created file on handle-less Nintendo target");

    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const path = try rootedPath(&path_buffer, sub_path, dataRoot());
    var open_flags: c_int = O_WRONLY;
    open_flags |= O_CREAT;
    if (flags.truncate) open_flags |= O_TRUNC;
    if (flags.exclusive) open_flags |= O_EXCL;

    const mode: c_int = if (@bitSizeOf(File.Permissions) == 0)
        0o666
    else
        @intCast(@intFromEnum(flags.permissions));
    const fd = c.open(path.ptr, open_flags, mode);
    if (fd < 0) return openError(errno());
    errdefer _ = c.close(fd);
    return registerFile(fd, .write);
}

fn fileStat(_: ?*anyopaque, file: File) File.StatError!File.Stat {
    return .{
        .inode = zero(File.INode),
        .nlink = zero(File.NLink),
        .size = try fileLength(null, file),
        .permissions = .default_file,
        .kind = .file,
        .atime = null,
        .mtime = now(null, .real),
        .ctime = now(null, .real),
        .block_size = 1,
    };
}

fn fileLength(_: ?*anyopaque, file: File) File.LengthError!u64 {
    const fd = fdForRegular(file);
    const current = c.lseek(fd, 0, SEEK_CUR);
    if (current < 0) return seekToLengthError();
    const end = c.lseek(fd, 0, SEEK_END);
    if (end < 0) return seekToLengthError();
    _ = c.lseek(fd, current, SEEK_SET);
    return @intCast(end);
}

fn fileClose(_: ?*anyopaque, files: []const File) void {
    for (files) |file| {
        if (isStderrFile(file)) continue;
        if (@sizeOf(File.Handle) != 0) {
            const fd = fdFromFileHandle(file);
            if (fd > 2) _ = c.close(fd);
            continue;
        }
        if (read_fd >= 0) {
            _ = c.close(read_fd);
            read_fd = -1;
        } else if (write_fd >= 0) {
            _ = c.close(write_fd);
            write_fd = -1;
        }
    }
}

fn fileReadPositional(
    _: ?*anyopaque,
    file: File,
    data: []const []u8,
    offset: u64,
) File.ReadPositionalError!usize {
    const fd = fdForRead(file);
    try seekToOffset(fd, offset);

    var total: usize = 0;
    for (data) |buf| {
        var remaining = buf;
        while (remaining.len > 0) {
            const n = c.read(fd, remaining.ptr, remaining.len);
            if (n < 0) return readError();
            if (n == 0) return total;
            const amt: usize = @intCast(n);
            total += amt;
            remaining = remaining[amt..];
            if (amt == 0) return total;
        }
    }
    return total;
}

fn fileReadStreaming(file: File, data: []const []u8) Io.Operation.FileReadStreaming.Result {
    const fd = fdForRead(file);
    var total: usize = 0;
    for (data) |buf| {
        var remaining = buf;
        while (remaining.len > 0) {
            const n = c.read(fd, remaining.ptr, remaining.len);
            if (n < 0) return readStreamingError();
            if (n == 0) return if (total == 0) error.EndOfStream else total;
            const amt: usize = @intCast(n);
            total += amt;
            remaining = remaining[amt..];
        }
    }
    return total;
}

fn fileWritePositional(
    _: ?*anyopaque,
    file: File,
    header: []const u8,
    data: []const []const u8,
    splat: usize,
    offset: u64,
) File.WritePositionalError!usize {
    const fd = fdForWrite(file);
    try seekToOffset(fd, offset);
    return writeVectors(fd, header, data, splat);
}

fn fileWriteStreaming(file: File, header: []const u8, data: []const []const u8, splat: usize) Io.Operation.FileWriteStreaming.Result {
    return writeVectors(fdForWrite(file), header, data, splat) catch |err| switch (err) {
        error.Canceled => unreachable,
        error.Unseekable => error.InputOutput,
        else => |e| @errorCast(e),
    };
}

fn fileSeekBy(_: ?*anyopaque, file: File, relative_offset: i64) File.SeekError!void {
    if (c.lseek(fdForRegular(file), @intCast(relative_offset), SEEK_CUR) < 0) return seekError();
}

fn fileSeekTo(_: ?*anyopaque, file: File, absolute_offset: u64) File.SeekError!void {
    try seekToOffset(fdForRegular(file), absolute_offset);
}

fn fileSync(_: ?*anyopaque, file: File) File.SyncError!void {
    if (isStderrFile(file)) return;
    if (c.fsync(fdForRegular(file)) < 0) return syncError();
}

fn fileIsTty(_: ?*anyopaque, _: File) Io.Cancelable!bool {
    return false;
}

fn fileEnableAnsiEscapeCodes(_: ?*anyopaque, _: File) File.EnableAnsiEscapeCodesError!void {
    return error.NotTerminalDevice;
}

fn fileSupportsAnsiEscapeCodes(_: ?*anyopaque, _: File) Io.Cancelable!bool {
    return false;
}

fn fileSetLength(_: ?*anyopaque, file: File, length: u64) File.SetLengthError!void {
    if (length > std.math.maxInt(c_long)) return error.FileTooBig;
    if (c.ftruncate(fdForRegular(file), @intCast(length)) < 0) return setLengthError();
}

fn lockStderr(_: ?*anyopaque, terminal_mode: ?Io.Terminal.Mode) Io.Cancelable!Io.LockedStderr {
    if (!stderr_writer_initialized) {
        var stderr_file: File = .{
            .handle = if (@sizeOf(File.Handle) == 0) {} else @as(File.Handle, @intCast(2)),
            .flags = .{ .nonblocking = true },
        };
        stderr_file.flags.nonblocking = true;
        stderr_writer = stderr_file.writerStreaming(io(), &empty_stderr_buffer);
        stderr_writer_initialized = true;
    }
    return .{
        .file_writer = &stderr_writer,
        .terminal_mode = terminal_mode orelse .no_color,
    };
}

fn tryLockStderr(userdata: ?*anyopaque, terminal_mode: ?Io.Terminal.Mode) Io.Cancelable!?Io.LockedStderr {
    return try lockStderr(userdata, terminal_mode);
}

fn unlockStderr(_: ?*anyopaque) void {
    if (stderr_writer_initialized) stderr_writer.interface.flush() catch {};
}

fn processCurrentPath(_: ?*anyopaque, buffer: []u8) std.process.CurrentPathError!usize {
    if (buffer.len == 0) return error.NameTooLong;
    const ptr = c.getcwd(buffer.ptr, buffer.len) orelse return currentPathError();
    const path = std.mem.span(ptr);
    if (path.len >= buffer.len) return error.NameTooLong;
    return path.len;
}

fn processSetCurrentPath(_: ?*anyopaque, path: []const u8) std.process.SetCurrentPathError!void {
    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const z = zPath(&path_buffer, path) catch |err| switch (err) {
        error.NameTooLong => return error.NameTooLong,
        error.BadPathName => return error.BadPathName,
    };
    if (c.chdir(z.ptr) < 0) return setCurrentPathError();
}

fn now(_: ?*anyopaque, clock: Io.Clock) Io.Timestamp {
    return platform_time.now(clock);
}

fn clockResolution(_: ?*anyopaque, clock: Io.Clock) Io.Clock.ResolutionError!Io.Duration {
    return platform_time.clockResolution(clock);
}

fn sleep(_: ?*anyopaque, timeout: Io.Timeout) Io.Cancelable!void {
    return platform_time.sleep(timeout);
}

fn random(_: ?*anyopaque, buffer: []u8) void {
    @memset(buffer, 0);
}

const FileRole = enum { read, write };

fn resourceRoot() []const u8 {
    return resource_root_buffer[0..resource_root_len];
}

fn dataRoot() []const u8 {
    return data_root_buffer[0..data_root_len];
}

fn setResourceRoot(root: []const u8) error{NameTooLong}!void {
    try setRoot(&resource_root_buffer, &resource_root_len, root);
}

fn setDataRoot(root: []const u8) error{NameTooLong}!void {
    try setRoot(&data_root_buffer, &data_root_len, root);
}

fn setRoot(buffer: *[max_path_bytes:0]u8, len: *usize, root: []const u8) error{NameTooLong}!void {
    if (root.len >= max_path_bytes) return error.NameTooLong;
    @memcpy(buffer[0..root.len], root);
    buffer[root.len] = 0;
    len.* = root.len;
}

fn registerFile(fd: c_int, role: FileRole) File {
    if (@sizeOf(File.Handle) == 0) {
        switch (role) {
            .read => {
                if (read_fd >= 0) unsupported("more than one regular read file");
                read_fd = fd;
            },
            .write => {
                if (write_fd >= 0) unsupported("more than one regular write file");
                write_fd = fd;
            },
        }
        return .{ .handle = {}, .flags = .{ .nonblocking = false } };
    }
    return .{
        .handle = @intCast(fd),
        .flags = .{ .nonblocking = false },
    };
}

fn fdForRead(file: File) c_int {
    if (@sizeOf(File.Handle) != 0) return fdFromFileHandle(file);
    if (read_fd < 0) unsupported("read from unopened regular file");
    return read_fd;
}

fn fdForWrite(file: File) c_int {
    if (isStderrFile(file)) return 2;
    if (@sizeOf(File.Handle) != 0) return fdFromFileHandle(file);
    if (write_fd < 0) unsupported("write to unopened regular file");
    return write_fd;
}

fn fdForRegular(file: File) c_int {
    if (isStderrFile(file)) unsupported("regular file operation on stderr");
    if (@sizeOf(File.Handle) != 0) return fdFromFileHandle(file);
    if (read_fd >= 0) return read_fd;
    if (write_fd >= 0) return write_fd;
    unsupported("regular file operation with no open file");
}

fn fdFromFileHandle(file: File) c_int {
    return @intCast(file.handle);
}

fn isStderrFile(file: File) bool {
    return file.flags.nonblocking;
}

fn seekToOffset(fd: c_int, offset: u64) File.SeekError!void {
    if (offset > std.math.maxInt(c_long)) return error.Unseekable;
    if (c.lseek(fd, @intCast(offset), SEEK_SET) < 0) return seekError();
}

fn writeVectors(fd: c_int, header: []const u8, data: []const []const u8, splat: usize) File.WritePositionalError!usize {
    var total: usize = 0;
    total += try writeOne(fd, header);
    for (0..splat) |_| {
        for (data) |buf| {
            total += try writeOne(fd, buf);
        }
    }
    return total;
}

fn writeOne(fd: c_int, bytes: []const u8) File.WritePositionalError!usize {
    var remaining = bytes;
    var total: usize = 0;
    while (remaining.len > 0) {
        const n = c.write(fd, remaining.ptr, remaining.len);
        if (n < 0) return writeError();
        if (n == 0) return total;
        const amt: usize = @intCast(n);
        total += amt;
        remaining = remaining[amt..];
    }
    return total;
}

fn zPath(buf: *[max_path_bytes:0]u8, path: []const u8) error{ NameTooLong, BadPathName }![:0]const u8 {
    if (path.len >= max_path_bytes) return error.NameTooLong;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn rootedPath(buf: *[max_path_bytes:0]u8, path: []const u8, root: []const u8) error{ NameTooLong, BadPathName }![:0]const u8 {
    if (isAbsoluteOrDevicePath(path) or root.len == 0) return zPath(buf, path);
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;

    const needs_sep = root.len > 0 and !std.mem.endsWith(u8, root, "/") and !std.mem.startsWith(u8, path, "/");
    const len = root.len + @intFromBool(needs_sep) + path.len;
    if (len >= max_path_bytes) return error.NameTooLong;

    var i: usize = 0;
    @memcpy(buf[i..][0..root.len], root);
    i += root.len;
    if (needs_sep) {
        buf[i] = '/';
        i += 1;
    }
    @memcpy(buf[i..][0..path.len], path);
    buf[len] = 0;
    return buf[0..len :0];
}

fn isAbsoluteOrDevicePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    const colon = std.mem.indexOfScalar(u8, path, ':') orelse return false;
    const slash = std.mem.indexOfAny(u8, path, "/\\") orelse path.len;
    return colon < slash;
}

fn ensureDirPath(path: []const u8) Dir.CreateDirPathOpenError!void {
    if (path.len == 0) return error.BadPathName;
    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const full = zPath(&path_buffer, path) catch |err| return err;
    const full_len = full.len;
    const full_ptr = path_buffer[0..].ptr;

    const start = pathRootEnd(path);
    var i = start;
    while (i < full_len) : (i += 1) {
        if (path_buffer[i] != '/') continue;
        if (i == start) continue;
        path_buffer[i] = 0;
        try createDir(full_ptr);
        path_buffer[i] = '/';
    }
    try createDir(full_ptr);
}

fn pathRootEnd(path: []const u8) usize {
    if (std.mem.indexOfScalar(u8, path, ':')) |colon| {
        if (colon + 1 < path.len and path[colon + 1] == '/') return colon + 2;
        return colon + 1;
    }
    return if (path.len > 0 and path[0] == '/') 1 else 0;
}

fn createDir(path: [*:0]const u8) Dir.CreateDirPathOpenError!void {
    if (c.mkdir(path, 0o777) == 0) return;
    switch (errno()) {
        17 => return,
        1 => return error.PermissionDenied,
        2 => return error.FileNotFound,
        6 => return error.NoDevice,
        12 => return error.SystemResources,
        13 => return error.AccessDenied,
        20 => return error.NotDir,
        28 => return error.NoSpaceLeft,
        30 => return error.ReadOnlyFileSystem,
        91 => return error.NameTooLong,
        92 => return error.SymLinkLoop,
        else => return error.Unexpected,
    }
}

fn errno() c_int {
    return c.__errno().*;
}

fn openError(code: c_int) File.OpenError {
    return switch (code) {
        1 => error.PermissionDenied,
        2 => error.FileNotFound,
        6 => error.NoDevice,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        16 => error.DeviceBusy,
        17 => error.PathAlreadyExists,
        20 => error.NotDir,
        21 => error.IsDir,
        23 => error.SystemFdQuotaExceeded,
        24 => error.ProcessFdQuotaExceeded,
        26 => error.FileBusy,
        27 => error.FileTooBig,
        28 => error.NoSpaceLeft,
        30 => error.ReadOnlyFileSystem,
        91 => error.NameTooLong,
        92 => error.SymLinkLoop,
        else => error.Unexpected,
    };
}

fn readError() File.ReadPositionalError {
    return switch (errno()) {
        5 => error.InputOutput,
        11 => error.WouldBlock,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        21 => error.IsDir,
        29 => error.Unseekable,
        else => error.Unexpected,
    };
}

fn readStreamingError() Io.Operation.FileReadStreaming.Error {
    return switch (errno()) {
        5 => error.InputOutput,
        11 => error.WouldBlock,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        21 => error.IsDir,
        else => error.Unexpected,
    };
}

fn writeError() File.WritePositionalError {
    return switch (errno()) {
        5 => error.InputOutput,
        6 => error.NoDevice,
        11 => error.WouldBlock,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        27 => error.FileTooBig,
        28 => error.NoSpaceLeft,
        29 => error.Unseekable,
        32 => error.BrokenPipe,
        else => error.Unexpected,
    };
}

fn seekError() File.SeekError {
    return switch (errno()) {
        13 => error.AccessDenied,
        29 => error.Unseekable,
        else => error.Unexpected,
    };
}

fn seekToLengthError() File.LengthError {
    return switch (errno()) {
        5 => error.Unexpected,
        13 => error.AccessDenied,
        29 => error.Streaming,
        else => error.Unexpected,
    };
}

fn syncError() File.SyncError {
    return switch (errno()) {
        5 => error.InputOutput,
        12 => error.Unexpected,
        13 => error.AccessDenied,
        28 => error.NoSpaceLeft,
        132 => error.DiskQuota,
        else => error.Unexpected,
    };
}

fn setLengthError() File.SetLengthError {
    return switch (errno()) {
        5 => error.InputOutput,
        13 => error.AccessDenied,
        16 => error.FileBusy,
        27 => error.FileTooBig,
        29 => error.NonResizable,
        else => error.Unexpected,
    };
}

fn currentPathError() std.process.CurrentPathError {
    return switch (errno()) {
        12 => error.Unexpected,
        91 => error.NameTooLong,
        else => error.CurrentDirUnlinked,
    };
}

fn setCurrentPathError() std.process.SetCurrentPathError {
    return switch (errno()) {
        2 => error.FileNotFound,
        13 => error.AccessDenied,
        20 => error.NotDir,
        91 => error.NameTooLong,
        else => error.Unexpected,
    };
}

fn zero(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .void => {},
        .int, .comptime_int => 0,
        else => @as(T, @intCast(0)),
    };
}

fn unsupported(comptime name: []const u8) noreturn {
    std.debug.panic("c std.Io baseline does not implement {s}", .{name});
}
