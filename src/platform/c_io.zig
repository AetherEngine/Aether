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
const platform_lifecycle = switch (options.config.platform) {
    .nintendo_3ds => @import("3ds/surface.zig"),
    else => struct {
        pub fn is_system_closing() bool {
            return false;
        }
    },
};

const c = @import("nintendo_c.zig").c;
const max_path_bytes = 1024;
const async_stack_size = 512 * 1024;

const AT_FDCWD: c_int = -2;
const O_RDONLY: c_int = c.O_RDONLY;
const O_WRONLY: c_int = c.O_WRONLY;
const O_RDWR: c_int = c.O_RDWR;
const O_CREAT: c_int = c.O_CREAT;
const O_TRUNC: c_int = c.O_TRUNC;
const O_EXCL: c_int = c.O_EXCL;
const O_BINARY: c_int = c.O_BINARY;
const O_CLOEXEC: c_int = c.O_CLOEXEC;
const O_NOFOLLOW: c_int = c.O_NOFOLLOW;
const SEEK_SET: c_int = c.SEEK_SET;
const SEEK_CUR: c_int = c.SEEK_CUR;
const SEEK_END: c_int = c.SEEK_END;

const DT_FIFO: u8 = c.DT_FIFO;
const DT_CHR: u8 = c.DT_CHR;
const DT_DIR: u8 = c.DT_DIR;
const DT_BLK: u8 = c.DT_BLK;
const DT_REG: u8 = c.DT_REG;
const DT_LNK: u8 = c.DT_LNK;
const DT_SOCK: u8 = c.DT_SOCK;
const DT_WHT: u8 = c.DT_WHT;

var read_fd: c_int = -1;
var write_fd: c_int = -1;
var stderr_writer: File.Writer = undefined;
var stderr_writer_initialized = false;
var empty_stderr_buffer: [0]u8 = .{};
var resources_mounted = false;
var data_mounted = false;
var atomic_counter: u64 = 0x6165_7468_6572_0000;

const max_dynamic_dirs = 32;
const DirSlot = struct {
    used: bool = false,
    path: [max_path_bytes:0]u8 = @splat(0),
    len: usize = 0,
};
var dir_slots: [max_dynamic_dirs]DirSlot = [_]DirSlot{.{}} ** max_dynamic_dirs;

const vtable: Io.VTable = blk: {
    var v = Io.failing.vtable.*;
    v.crashHandler = crashHandler;
    if (options.config.platform == .nintendo_3ds) {
        v.async = threed_async.async;
        v.concurrent = threed_async.concurrent;
        v.await = threed_async.await;
        v.cancel = threed_async.cancel;
    } else {
        v.async = Io.noAsync;
    }
    v.groupAsync = Io.noGroupAsync;
    v.recancel = recancel;
    v.swapCancelProtection = swapCancelProtection;
    v.checkCancel = checkCancel;
    v.operate = operate;
    v.dirCreateDir = dirCreateDir;
    v.dirCreateDirPath = dirCreateDirPath;
    v.dirCreateDirPathOpen = dirCreateDirPathOpen;
    v.dirOpenDir = dirOpenDir;
    v.dirAccess = dirAccess;
    v.dirCreateFile = dirCreateFile;
    v.dirCreateFileAtomic = dirCreateFileAtomic;
    v.dirOpenFile = dirOpenFile;
    v.dirClose = dirClose;
    v.dirRead = dirRead;
    v.dirDeleteFile = dirDeleteFile;
    v.dirDeleteDir = dirDeleteDir;
    v.dirRename = dirRename;
    v.dirRenamePreserve = dirRenamePreserve;
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

pub fn cwd() Dir {
    return .{ .handle = AT_FDCWD };
}

pub fn mountData() void {
    data_mounted = platform_paths.mountData();
}

pub fn mountResources() bool {
    resources_mounted = platform_paths.mountResources();
    return resources_mounted;
}

pub fn dataRoot(buffer: []u8, app_name: []const u8) error{NameTooLong}![]const u8 {
    return platform_paths.dataRoot(buffer, app_name);
}

pub fn deinitAppDirs() void {
    for (&dir_slots) |*slot| slot.used = false;
    if (platform_lifecycle.is_system_closing()) {
        resources_mounted = false;
        data_mounted = false;
        return;
    }
    if (resources_mounted) {
        platform_paths.unmountResources();
        resources_mounted = false;
    }
    if (data_mounted) {
        platform_paths.unmountData();
        data_mounted = false;
    }
}

pub fn useCwdDirs() void {
    deinitAppDirs();
}

fn crashHandler(_: ?*anyopaque) void {}

fn recancel(_: ?*anyopaque) void {}

fn swapCancelProtection(_: ?*anyopaque, new: Io.CancelProtection) Io.CancelProtection {
    _ = new;
    return .unblocked;
}

fn checkCancel(_: ?*anyopaque) Io.Cancelable!void {}

const threed_async = if (options.config.platform == .nintendo_3ds) struct {
    const AsyncFuture = struct {
        thread: c.Thread,
        result_len: usize,
        result_offset: usize,
        context_offset: usize,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,

        fn result(self: *AsyncFuture) []u8 {
            const base: [*]u8 = @ptrCast(self);
            return base[self.result_offset..][0..self.result_len];
        }

        fn context(self: *AsyncFuture) *const anyopaque {
            const base: [*]u8 = @ptrCast(self);
            return @ptrCast(base + self.context_offset);
        }
    };

    fn allocFuture(
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*AsyncFuture {
        const result_offset = result_alignment.forward(@sizeOf(AsyncFuture));
        const context_offset = context_alignment.forward(result_offset + result_len);
        const total = context_offset + context.len;

        const raw = c.malloc(total) orelse return null;
        const future: *AsyncFuture = @ptrCast(@alignCast(raw));
        future.* = .{
            .thread = null,
            .result_len = result_len,
            .result_offset = result_offset,
            .context_offset = context_offset,
            .start = start,
        };

        const base: [*]u8 = @ptrCast(future);
        @memcpy(base[context_offset..][0..context.len], context);
        return future;
    }

    fn freeFuture(future: *AsyncFuture) void {
        c.free(future);
    }

    fn entry(raw: ?*anyopaque) callconv(.c) void {
        const future: *AsyncFuture = @ptrCast(@alignCast(raw.?));
        future.start(future.context(), future.result().ptr);
    }

    fn spawn(future: *AsyncFuture) bool {
        future.thread = c.threadCreate(
            entry,
            future,
            async_stack_size,
            workerPriority(),
            -2,
            false,
        ) orelse return false;
        return true;
    }

    fn workerPriority() c_int {
        var priority: c.s32 = 0x30;
        if (c.threadGetCurrent()) |current| {
            const handle = c.threadGetHandle(current);
            _ = c.svcGetThreadPriority(&priority, handle);
        }
        return @min(priority + 1, 0x3f);
    }

    fn async(
        _: ?*anyopaque,
        result: []u8,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) ?*Io.AnyFuture {
        const future = allocFuture(result.len, result_alignment, context, context_alignment, start) orelse {
            start(context.ptr, result.ptr);
            return null;
        };
        if (!spawn(future)) {
            freeFuture(future);
            start(context.ptr, result.ptr);
            return null;
        }
        return @ptrCast(future);
    }

    fn concurrent(
        _: ?*anyopaque,
        result_len: usize,
        result_alignment: std.mem.Alignment,
        context: []const u8,
        context_alignment: std.mem.Alignment,
        start: *const fn (context: *const anyopaque, result: *anyopaque) void,
    ) Io.ConcurrentError!*Io.AnyFuture {
        const future = allocFuture(result_len, result_alignment, context, context_alignment, start) orelse
            return error.ConcurrencyUnavailable;
        errdefer freeFuture(future);
        if (!spawn(future)) return error.ConcurrencyUnavailable;
        return @ptrCast(future);
    }

    fn await(
        _: ?*anyopaque,
        any_future: *Io.AnyFuture,
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void {
        _ = result_alignment;
        const future: *AsyncFuture = @ptrCast(@alignCast(any_future));
        _ = c.threadJoin(future.thread, std.math.maxInt(u64));
        c.threadFree(future.thread);
        @memcpy(result, future.result());
        freeFuture(future);
    }

    fn cancel(
        userdata: ?*anyopaque,
        any_future: *Io.AnyFuture,
        result: []u8,
        result_alignment: std.mem.Alignment,
    ) void {
        await(userdata, any_future, result, result_alignment);
    }
} else struct {};

fn operate(_: ?*anyopaque, operation: Io.Operation) Io.Cancelable!Io.Operation.Result {
    return switch (operation) {
        .file_read_streaming => |op| .{ .file_read_streaming = fileReadStreaming(op.file, op.data) },
        .file_write_streaming => |op| .{ .file_write_streaming = fileWriteStreaming(op.file, op.header, op.data, op.splat) },
        .device_io_control => unsupported("device_io_control"),
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
    };
}

fn dirCreateDir(
    _: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
) Dir.CreateDirError!void {
    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const path = try rootedPathForDir(&path_buffer, dir, sub_path);
    const mode = permissionsMode(permissions, 0o777);
    if (c.mkdir(path.ptr, mode) == 0) return;
    return createDirError(errno());
}

fn dirCreateDirPath(
    _: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
) Dir.CreateDirPathError!Dir.CreatePathStatus {
    return createDirPathAt(dir, sub_path, permissions);
}

fn dirCreateDirPathOpen(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    permissions: Dir.Permissions,
    open_options: Dir.OpenOptions,
) Dir.CreateDirPathOpenError!Dir {
    _ = try dirCreateDirPath(userdata, dir, sub_path, permissions);
    return dirOpenDir(userdata, dir, sub_path, open_options);
}

fn dirOpenDir(_: ?*anyopaque, dir: Dir, sub_path: []const u8, options_arg: Dir.OpenOptions) Dir.OpenError!Dir {
    if (!options_arg.access_sub_paths) unsupported("dirOpenDir without sub-path access");

    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const path = try rootedPathForDir(&path_buffer, dir, sub_path);
    const stream = c.opendir(path.ptr) orelse return dirOpenError(errno());
    _ = c.closedir(stream);

    return registerDir(path);
}

fn dirAccess(_: ?*anyopaque, dir: Dir, sub_path: []const u8, opts: Dir.AccessOptions) Dir.AccessError!void {
    if (!opts.follow_symlinks) unsupported("dirAccess without symlink following");

    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const path = try rootedPathForDir(&path_buffer, dir, sub_path);
    const fd = c.open(path.ptr, O_BINARY | O_RDONLY | O_CLOEXEC, @as(c.mode_t, 0));
    if (fd < 0) return accessError(errno());
    _ = c.close(fd);
}

fn dirOpenFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8, flags: Dir.OpenFileOptions) File.OpenError!File {
    if (flags.lock != .none) return error.FileLocksUnsupported;
    if (flags.path_only) unsupported("path-only file open");
    if (!flags.allow_ctty) {}

    const role: FileRole = switch (flags.mode) {
        .read_only => .read,
        .write_only => .write,
        .read_write => .read_write,
    };

    var path_buffer: [max_path_bytes:0]u8 = undefined;
    var open_flags: c_int = O_BINARY | O_CLOEXEC | switch (flags.mode) {
        .read_only => O_RDONLY,
        .write_only => O_WRONLY,
        .read_write => O_RDWR,
    };
    if (!flags.follow_symlinks) open_flags |= O_NOFOLLOW;

    const path = try rootedPathForDir(&path_buffer, dir, sub_path);
    const fd = c.open(path.ptr, open_flags, @as(c.mode_t, 0));
    if (fd < 0) return openError(errno());
    errdefer _ = c.close(fd);
    return registerFile(fd, role);
}

fn dirCreateFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8, flags: Dir.CreateFileOptions) File.OpenError!File {
    if (flags.lock != .none) return error.FileLocksUnsupported;

    var path_buffer: [max_path_bytes:0]u8 = undefined;
    var open_flags: c_int = O_BINARY | O_CLOEXEC | if (flags.read) O_RDWR else O_WRONLY;
    open_flags |= O_CREAT;
    if (flags.truncate) open_flags |= O_TRUNC;
    if (flags.exclusive) open_flags |= O_EXCL;

    const mode = permissionsMode(flags.permissions, 0o666);
    const path = try rootedPathForDir(&path_buffer, dir, sub_path);
    const fd = c.open(path.ptr, open_flags, mode);
    if (fd < 0) return openError(errno());
    errdefer _ = c.close(fd);
    return registerFile(fd, if (flags.read) .read_write else .write);
}

fn dirCreateFileAtomic(
    userdata: ?*anyopaque,
    dir: Dir,
    sub_path: []const u8,
    opts: Dir.CreateFileAtomicOptions,
) Dir.CreateFileAtomicError!File.Atomic {
    var target_dir = dir;
    var close_target_dir = false;
    var dest_sub_path = sub_path;
    errdefer if (close_target_dir) target_dir.close(io());

    if (std.fs.path.dirname(sub_path)) |parent| {
        target_dir = if (opts.make_path)
            dirCreateDirPathOpen(userdata, dir, parent, .default_dir, .{}) catch |err| return createFileAtomicDirError(err)
        else
            dirOpenDir(userdata, dir, parent, .{}) catch |err| return createFileAtomicDirError(err);
        close_target_dir = true;
        dest_sub_path = std.fs.path.basename(sub_path);
    } else if (opts.make_path) {
        _ = opts.make_path;
    }

    var attempts: u8 = 0;
    while (attempts < 16) : (attempts += 1) {
        atomic_counter +%= 1;
        const basename_hex = atomic_counter;
        const tmp_sub_path = std.fmt.hex(basename_hex);
        const file = dirCreateFile(userdata, target_dir, &tmp_sub_path, .{
            .read = true,
            .exclusive = true,
            .permissions = opts.permissions,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            error.FileTooBig, error.IsDir, error.DeviceBusy, error.FileLocksUnsupported, error.PipeBusy => return error.Unexpected,
            else => |e| return @errorCast(e),
        };
        errdefer file.close(io());

        const result: File.Atomic = .{
            .file = file,
            .file_basename_hex = basename_hex,
            .file_open = true,
            .file_exists = true,
            .dir = target_dir,
            .close_dir_on_deinit = close_target_dir,
            .dest_sub_path = dest_sub_path,
        };
        close_target_dir = false;
        return result;
    }

    return error.SystemResources;
}

fn dirClose(_: ?*anyopaque, dirs: []const Dir) void {
    for (dirs) |dir| {
        if (dirSlotIndex(dir)) |i| dir_slots[i].used = false;
    }
}

fn dirRead(_: ?*anyopaque, reader: *Dir.Reader, out: []Dir.Entry) Dir.Reader.Error!usize {
    const Header = extern struct {
        pos: c_long,
    };
    const header_end = @sizeOf(Header);
    if (reader.index < header_end) {
        reader.index = header_end;
        reader.end = header_end;
        const header: *Header = @ptrCast(@alignCast(reader.buffer.ptr));
        header.* = .{ .pos = 0 };
    }

    const header: *Header = @ptrCast(@alignCast(reader.buffer.ptr));
    if (reader.state == .reset) {
        header.pos = 0;
        reader.state = .reading;
    }
    if (reader.state == .finished) return 0;

    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const root = dirRoot(reader.dir);
    const path = zPath(&path_buffer, if (root.len == 0) "." else root) catch return error.Unexpected;
    const stream = c.opendir(path.ptr) orelse return dirReadError(errno());
    var stream_open = true;
    defer if (stream_open) {
        _ = c.closedir(stream);
    };

    const use_direct_dirnext = options.config.platform == .nintendo_3ds;
    if (!use_direct_dirnext) c.seekdir(stream, header.pos);

    const dir_dev = if (use_direct_dirnext) c.devoptab_list[@intCast(stream.*.dirData.*.device)] else null;
    const dirnext = if (use_direct_dirnext) dir_dev.*.dirnext_r.? else {};
    const reent = if (use_direct_dirnext) c.__syscall_getreent() else {};
    var direct_name: [Dir.max_name_bytes + 1]u8 = @splat(0);
    var direct_stat: c.struct_stat = undefined;
    if (use_direct_dirnext) {
        var skipped: c_long = 0;
        while (skipped < header.pos) : (skipped += 1) {
            if (dirnext(reent, stream.*.dirData, &direct_name, &direct_stat) != 0) {
                reader.state = .finished;
                return 0;
            }
        }
    }

    var count: usize = 0;
    var name_end = reader.buffer.len;
    while (count < out.len) {
        const name, const kind, const inode = if (use_direct_dirnext) direct: {
            @memset(&direct_name, 0);
            direct_stat = undefined;
            if (dirnext(reent, stream.*.dirData, &direct_name, &direct_stat) != 0) {
                reader.state = .finished;
                return count;
            }
            header.pos += 1;
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&direct_name)));
            break :direct .{ name, statKind(direct_stat.st_mode), @as(File.INode, @intCast(direct_stat.st_ino)) };
        } else libc: {
            c.__errno().* = 0;
            const entry = c.readdir(stream) orelse {
                if (errno() != 0) return dirReadError(errno());
                reader.state = .finished;
                return count;
            };
            header.pos = c.telldir(stream);
            const name = std.mem.span(@as([*:0]const u8, @ptrCast(&entry.*.d_name)));
            break :libc .{ name, direntKind(entry.*.d_type), @as(File.INode, @intCast(entry.*.d_ino)) };
        };
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
        if (name.len + 1 > name_end - header_end) {
            if (count == 0) return error.Unexpected;
            break;
        }

        name_end -= name.len + 1;
        @memcpy(reader.buffer[name_end..][0..name.len], name);
        reader.buffer[name_end + name.len] = 0;
        out[count] = .{
            .name = reader.buffer[name_end .. name_end + name.len],
            .kind = kind,
            .inode = inode,
        };
        count += 1;
    }

    stream_open = false;
    _ = c.closedir(stream);
    return count;
}

fn dirDeleteFile(_: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteFileError!void {
    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const path = try rootedPathForDir(&path_buffer, dir, sub_path);
    if (c.unlink(path.ptr) == 0) return;
    return deleteFileError(errno());
}

fn dirDeleteDir(_: ?*anyopaque, dir: Dir, sub_path: []const u8) Dir.DeleteDirError!void {
    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const path = try rootedPathForDir(&path_buffer, dir, sub_path);
    if (c.rmdir(path.ptr) == 0) return;
    return deleteDirError(errno());
}

fn dirRename(
    _: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenameError!void {
    var old_path_buffer: [max_path_bytes:0]u8 = undefined;
    var new_path_buffer: [max_path_bytes:0]u8 = undefined;
    const old_path = try rootedPathForDir(&old_path_buffer, old_dir, old_sub_path);
    const new_path = try rootedPathForDir(&new_path_buffer, new_dir, new_sub_path);
    if (c.rename(old_path.ptr, new_path.ptr) == 0) return;
    return renameError(errno());
}

fn dirRenamePreserve(
    userdata: ?*anyopaque,
    old_dir: Dir,
    old_sub_path: []const u8,
    new_dir: Dir,
    new_sub_path: []const u8,
) Dir.RenamePreserveError!void {
    dirAccess(userdata, new_dir, new_sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return @errorCast(e),
    };
    if (dirAccess(userdata, new_dir, new_sub_path, .{})) |_| return error.PathAlreadyExists else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return @errorCast(e),
    }
    return dirRename(userdata, old_dir, old_sub_path, new_dir, new_sub_path) catch |err| switch (err) {
        error.DiskQuota, error.IsDir, error.LinkQuotaExceeded, error.NoDevice, error.PipeBusy, error.AntivirusInterference, error.HardwareFailure => return error.Unexpected,
        else => |e| return @errorCast(e),
    };
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
        if (read_fd >= 0 and read_fd == write_fd) {
            _ = c.close(read_fd);
            read_fd = -1;
            write_fd = -1;
        } else if (read_fd >= 0) {
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
    if (length > std.math.maxInt(c.off_t)) return error.FileTooBig;
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
    _ = ptr;
    return std.mem.indexOfScalar(u8, buffer, 0) orelse error.NameTooLong;
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

const FileRole = enum { read, write, read_write };

fn createDirPathAt(dir: Dir, sub_path: []const u8, permissions: Dir.Permissions) Dir.CreateDirPathError!Dir.CreatePathStatus {
    if (sub_path.len == 0) return error.BadPathName;

    var path_buffer: [max_path_bytes:0]u8 = undefined;
    const full = rootedPathForDir(&path_buffer, dir, sub_path) catch |err| return err;
    const full_len = full.len;
    const full_ptr = path_buffer[0..].ptr;
    const mode = permissionsMode(permissions, 0o777);

    var status: Dir.CreatePathStatus = .existed;
    const start = pathRootEnd(full);
    var i = start;
    while (i < full_len) : (i += 1) {
        if (path_buffer[i] != '/') continue;
        if (i == start) continue;
        path_buffer[i] = 0;
        if (try createSingleDirPath(full_ptr, mode) == .created) status = .created;
        path_buffer[i] = '/';
    }
    if (try createSingleDirPath(full_ptr, mode) == .created) status = .created;
    return status;
}

fn createSingleDirPath(path: [*:0]const u8, mode: c.mode_t) Dir.CreateDirPathError!Dir.CreatePathStatus {
    if (c.mkdir(path, mode) == 0) return .created;
    switch (errno()) {
        17 => return .existed,
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
            .read_write => {
                if (read_fd >= 0) unsupported("more than one regular read file");
                if (write_fd >= 0) unsupported("more than one regular write file");
                read_fd = fd;
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

fn fdFromDirHandle(dir: Dir) c_int {
    return @intCast(dir.handle);
}

fn permissionsMode(permissions: File.Permissions, default: c.mode_t) c.mode_t {
    if (@bitSizeOf(File.Permissions) == 0) return default;
    return @intCast(@intFromEnum(permissions));
}

fn isStderrFile(file: File) bool {
    return file.flags.nonblocking;
}

fn registerDir(path: []const u8) Dir.OpenError!Dir {
    for (&dir_slots, 0..) |*slot, i| {
        if (slot.used) continue;
        if (path.len >= max_path_bytes) return error.NameTooLong;
        @memcpy(slot.path[0..path.len], path);
        slot.path[path.len] = 0;
        slot.len = path.len;
        slot.used = true;
        return .{ .handle = @intCast(i + 3) };
    }
    return error.SystemResources;
}

fn dirSlotIndex(dir: Dir) ?usize {
    const handle = fdFromDirHandle(dir);
    if (handle < 3) return null;
    const index: usize = @intCast(handle - 3);
    if (index >= dir_slots.len or !dir_slots[index].used) return null;
    return index;
}

fn dirRoot(dir: Dir) []const u8 {
    if (fdFromDirHandle(dir) == AT_FDCWD) return "";
    const index = dirSlotIndex(dir) orelse unsupported("closed Nintendo dir handle");
    return dir_slots[index].path[0..dir_slots[index].len];
}

fn rootedPath(buf: *[max_path_bytes:0]u8, path: []const u8, root: []const u8) error{ NameTooLong, BadPathName }![:0]const u8 {
    if (isAbsoluteOrDevicePath(path) or root.len == 0) return zPath(buf, path);
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.BadPathName;

    const needs_sep = !std.mem.endsWith(u8, root, "/") and !std.mem.startsWith(u8, path, "/");
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

fn rootedPathForDir(buf: *[max_path_bytes:0]u8, dir: Dir, path: []const u8) error{ NameTooLong, BadPathName }![:0]const u8 {
    return rootedPath(buf, path, dirRoot(dir));
}

fn direntKind(kind: u8) File.Kind {
    return switch (kind) {
        DT_BLK => .block_device,
        DT_CHR => .character_device,
        DT_DIR => .directory,
        DT_FIFO => .named_pipe,
        DT_LNK => .sym_link,
        DT_REG => .file,
        DT_SOCK => .unix_domain_socket,
        DT_WHT => .whiteout,
        else => .unknown,
    };
}

fn statKind(mode: c.mode_t) File.Kind {
    if (c.S_ISBLK(mode)) return .block_device;
    if (c.S_ISCHR(mode)) return .character_device;
    if (c.S_ISDIR(mode)) return .directory;
    if (c.S_ISFIFO(mode)) return .named_pipe;
    if (c.S_ISLNK(mode)) return .sym_link;
    if (c.S_ISREG(mode)) return .file;
    if (c.S_ISSOCK(mode)) return .unix_domain_socket;
    return .unknown;
}

fn seekToOffset(fd: c_int, offset: u64) File.SeekError!void {
    if (offset > std.math.maxInt(c.off_t)) return error.Unseekable;
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

fn isAbsoluteOrDevicePath(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/') return true;
    const colon = std.mem.indexOfScalar(u8, path, ':') orelse return false;
    const slash = std.mem.indexOfAny(u8, path, "/\\") orelse path.len;
    return colon < slash;
}

fn pathRootEnd(path: []const u8) usize {
    if (std.mem.indexOfScalar(u8, path, ':')) |colon| {
        if (colon + 1 < path.len and path[colon + 1] == '/') return colon + 2;
        return colon + 1;
    }
    return if (path.len > 0 and path[0] == '/') 1 else 0;
}

fn createFileAtomicDirError(err: anyerror) Dir.CreateFileAtomicError {
    return switch (err) {
        error.PathAlreadyExists, error.NotDir => error.NotDir,
        error.FileTooBig, error.IsDir, error.DeviceBusy, error.FileLocksUnsupported => error.Unexpected,
        else => @errorCast(err),
    };
}

fn errno() c_int {
    return c.__errno().*;
}

fn createDirError(code: c_int) Dir.CreateDirError {
    return switch (code) {
        1 => error.PermissionDenied,
        2 => error.FileNotFound,
        6 => error.NoDevice,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        17 => error.PathAlreadyExists,
        20 => error.NotDir,
        28 => error.NoSpaceLeft,
        30 => error.ReadOnlyFileSystem,
        91 => error.NameTooLong,
        92 => error.SymLinkLoop,
        else => error.Unexpected,
    };
}

fn accessError(code: c_int) Dir.AccessError {
    return switch (code) {
        1 => error.PermissionDenied,
        2 => error.FileNotFound,
        5 => error.InputOutput,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        16 => error.FileBusy,
        30 => error.ReadOnlyFileSystem,
        91 => error.NameTooLong,
        92 => error.SymLinkLoop,
        else => error.Unexpected,
    };
}

fn dirOpenError(code: c_int) Dir.OpenError {
    return switch (code) {
        1 => error.PermissionDenied,
        2 => error.FileNotFound,
        6 => error.NoDevice,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        20 => error.NotDir,
        23 => error.ProcessFdQuotaExceeded,
        24 => error.SystemFdQuotaExceeded,
        91 => error.NameTooLong,
        92 => error.SymLinkLoop,
        else => error.Unexpected,
    };
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

fn deleteFileError(code: c_int) Dir.DeleteFileError {
    return switch (code) {
        1 => error.PermissionDenied,
        2 => error.FileNotFound,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        16 => error.FileBusy,
        20 => error.NotDir,
        21 => error.IsDir,
        30 => error.ReadOnlyFileSystem,
        91 => error.NameTooLong,
        92 => error.SymLinkLoop,
        else => error.Unexpected,
    };
}

fn deleteDirError(code: c_int) Dir.DeleteDirError {
    return switch (code) {
        1 => error.PermissionDenied,
        2 => error.FileNotFound,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        16 => error.FileBusy,
        20 => error.NotDir,
        30 => error.ReadOnlyFileSystem,
        39 => error.DirNotEmpty,
        91 => error.NameTooLong,
        92 => error.SymLinkLoop,
        else => error.Unexpected,
    };
}

fn renameError(code: c_int) Dir.RenameError {
    return switch (code) {
        1 => error.PermissionDenied,
        2 => error.FileNotFound,
        5 => error.HardwareFailure,
        6 => error.NoDevice,
        12 => error.SystemResources,
        13 => error.AccessDenied,
        16 => error.FileBusy,
        18 => error.CrossDevice,
        20 => error.NotDir,
        21 => error.IsDir,
        28 => error.NoSpaceLeft,
        30 => error.ReadOnlyFileSystem,
        39 => error.DirNotEmpty,
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

fn dirReadError(code: c_int) Dir.Reader.Error {
    return switch (code) {
        1 => error.PermissionDenied,
        12 => error.SystemResources,
        13 => error.AccessDenied,
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
