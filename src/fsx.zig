//! Version-portable filesystem/environment shim.
//!
//! Zig 0.16 moved `std.fs` under `std.Io.Dir`/`std.Io.File` (every
//! operation now takes an explicit `Io` instance) and dropped
//! `std.posix.getenv`/`getcwd` and friends. issy supports both the
//! 0.15.x and 0.16.x series from one source tree, so every file/env
//! operation in src/ goes through this module instead of std.fs:
//!
//!   - On 0.15, everything delegates to `std.fs` exactly as before —
//!     the 0.15 build is byte-for-byte the pre-shim behavior.
//!   - On 0.16, operations delegate to `std.Io.Dir`/`std.Io.File`
//!     using a module-global blocking `std.Io.Threaded` instance,
//!     created lazily on first use. issy is single-threaded and all
//!     its I/O is synchronous, so one global instance is sound.
//!
//! Only the operations issy actually uses are wrapped. If you need a
//! new fs call, add it here for both versions rather than reaching
//! for std.fs/std.Io directly.

const std = @import("std");
const builtin = @import("builtin");

pub const is_zig_016 = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;

pub const max_path_bytes = std.fs.max_path_bytes;

// ── 0.16 global blocking Io ─────────────────────────────────────────

var threaded_state: enum { uninit, ready } = .uninit;
var threaded: if (is_zig_016) std.Io.Threaded else void = undefined;

/// The process-wide blocking Io instance (0.16 only). Public so the
/// one other Io consumer (update.zig's HTTP client) can share it.
pub fn io() if (is_zig_016) std.Io else void {
    if (comptime !is_zig_016) return {};
    if (threaded_state == .uninit) {
        threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        threaded_state = .ready;
    }
    return threaded.io();
}

// ── Stat ────────────────────────────────────────────────────────────

pub const Kind = enum { file, directory, sym_link, other };

pub const Stat = struct {
    size: u64,
    /// Nanoseconds since epoch, matching 0.15 std.fs.File.Stat.mtime.
    mtime: i128,
    kind: Kind,
    /// Posix permission bits (low 12 bits meaningful).
    mode: u32,
};

fn mapKind(k: anytype) Kind {
    return switch (k) {
        .file => .file,
        .directory => .directory,
        .sym_link => .sym_link,
        else => .other,
    };
}

fn statFrom015(st: std.fs.File.Stat) Stat {
    return .{
        .size = st.size,
        .mtime = st.mtime,
        .kind = mapKind(st.kind),
        .mode = @intCast(st.mode & 0o7777),
    };
}

fn statFrom016(st: anytype) Stat {
    return .{
        .size = st.size,
        .mtime = @as(i128, st.mtime.nanoseconds),
        .kind = mapKind(st.kind),
        .mode = @intCast(@intFromEnum(st.permissions) & 0o7777),
    };
}

// ── File ────────────────────────────────────────────────────────────

pub const File = if (!is_zig_016) std.fs.File else struct {
    handle: std.posix.fd_t,

    pub const Mode = u32;

    fn inner(self: @This()) std.Io.File {
        return .{ .handle = self.handle, .flags = .{ .nonblocking = false } };
    }

    pub fn stdin() @This() {
        return .{ .handle = std.Io.File.stdin().handle };
    }
    pub fn stdout() @This() {
        return .{ .handle = std.Io.File.stdout().handle };
    }
    pub fn stderr() @This() {
        return .{ .handle = std.Io.File.stderr().handle };
    }

    pub fn close(self: @This()) void {
        self.inner().close(io());
    }

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        return self.inner().writeStreamingAll(io(), bytes);
    }

    pub fn write(self: @This(), bytes: []const u8) !usize {
        return self.inner().writeStreaming(io(), "", &.{bytes}, 1);
    }

    pub fn read(self: @This(), buffer: []u8) !usize {
        return self.inner().readStreaming(io(), &.{buffer}) catch |err| switch (err) {
            error.EndOfStream => 0,
            else => err,
        };
    }

    pub fn readAll(self: @This(), buffer: []u8) !usize {
        var total: usize = 0;
        while (total < buffer.len) {
            // 0.16 readStreaming reports EOF as error.EndOfStream rather
            // than a zero-length read.
            const n = self.inner().readStreaming(io(), &.{buffer[total..]}) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (n == 0) break;
            total += n;
        }
        return total;
    }

    pub fn stat(self: @This()) !Stat {
        return statFrom016(try self.inner().stat(io()));
    }

    pub fn sync(self: @This()) !void {
        return self.inner().sync(io());
    }
};

/// fsx.File.stat() on 0.15 returns std.fs.File.Stat (kind/mode typed
/// differently than fsx.Stat). statFile() below normalizes; for
/// File.stat() call sites that only touch .size/.mtime the native
/// return works on both sides.
pub fn fileStat(file: File) !Stat {
    if (comptime !is_zig_016) return statFrom015(try file.stat());
    return file.stat();
}

// ── Directory (cwd-relative) operations ─────────────────────────────

pub fn openFile(path: []const u8) !File {
    if (comptime !is_zig_016) return std.fs.cwd().openFile(path, .{});
    const f = try std.Io.Dir.cwd().openFile(io(), path, .{});
    return .{ .handle = f.handle };
}

pub const CreateOpts = struct {
    truncate: bool = true,
    exclusive: bool = false,
    mode: u32 = 0o666,
};

pub fn createFile(path: []const u8, opts: CreateOpts) !File {
    if (comptime !is_zig_016) return std.fs.cwd().createFile(path, .{
        .truncate = opts.truncate,
        .exclusive = opts.exclusive,
        .mode = @intCast(opts.mode),
    });
    const f = try std.Io.Dir.cwd().createFile(io(), path, .{
        .truncate = opts.truncate,
        .exclusive = opts.exclusive,
        .permissions = @enumFromInt(opts.mode),
    });
    return .{ .handle = f.handle };
}

pub fn deleteFile(path: []const u8) !void {
    if (comptime !is_zig_016) return std.fs.cwd().deleteFile(path);
    return std.Io.Dir.cwd().deleteFile(io(), path);
}

pub fn rename(old_path: []const u8, new_path: []const u8) !void {
    if (comptime !is_zig_016) return std.fs.cwd().rename(old_path, new_path);
    return std.Io.Dir.cwd().rename(old_path, std.Io.Dir.cwd(), new_path, io());
}

pub fn access(path: []const u8) !void {
    if (comptime !is_zig_016) return std.fs.cwd().access(path, .{});
    return std.Io.Dir.cwd().access(io(), path, .{});
}

pub fn makePath(path: []const u8) !void {
    if (comptime !is_zig_016) return std.fs.cwd().makePath(path);
    return std.Io.Dir.cwd().createDirPath(io(), path);
}

pub fn readLink(path: []const u8, buffer: []u8) ![]u8 {
    if (comptime !is_zig_016) return std.fs.cwd().readLink(path, buffer);
    const n = try std.Io.Dir.cwd().readLink(io(), path, buffer);
    return buffer[0..n];
}

pub fn copyFile(src: []const u8, dst: []const u8) !void {
    if (comptime !is_zig_016) return std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{});
    return std.Io.Dir.cwd().copyFile(src, std.Io.Dir.cwd(), dst, io(), .{});
}

pub fn symLink(target: []const u8, link_path: []const u8) !void {
    if (comptime !is_zig_016) return std.fs.cwd().symLink(target, link_path, .{});
    return std.Io.Dir.cwd().symLink(io(), target, link_path, .{});
}

pub fn statFile(path: []const u8) !Stat {
    if (comptime !is_zig_016) return statFrom015(try std.fs.cwd().statFile(path));
    return statFrom016(try std.Io.Dir.cwd().statFile(io(), path, .{}));
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    if (comptime !is_zig_016) return std.fs.cwd().readFileAlloc(allocator, path, max_bytes);
    return std.Io.Dir.cwd().readFileAlloc(io(), path, allocator, .limited(max_bytes));
}

// ── Directory iteration (path completion) ───────────────────────────

pub const IterEntry = struct {
    name: []const u8,
    kind: Kind,
};

pub const Dir = if (!is_zig_016) struct {
    inner: std.fs.Dir,

    pub fn close(self: *@This()) void {
        self.inner.close();
    }

    pub const Iterator = struct {
        inner: std.fs.Dir.Iterator,

        pub fn next(self: *@This()) !?IterEntry {
            const e = (try self.inner.next()) orelse return null;
            return .{ .name = e.name, .kind = mapKind(e.kind) };
        }
    };

    pub fn iterate(self: *@This()) Iterator {
        return .{ .inner = self.inner.iterate() };
    }
} else struct {
    inner: std.Io.Dir,

    pub fn close(self: *@This()) void {
        self.inner.close(io());
    }

    pub const Iterator = struct {
        inner: std.Io.Dir.Iterator,

        pub fn next(self: *@This()) !?IterEntry {
            const e = (try self.inner.next(io())) orelse return null;
            return .{ .name = e.name, .kind = mapKind(e.kind) };
        }
    };

    pub fn iterate(self: *@This()) Iterator {
        return .{ .inner = self.inner.iterate() };
    }
};

pub fn openDirIterable(path: []const u8) !Dir {
    if (comptime !is_zig_016) return .{ .inner = try std.fs.cwd().openDir(path, .{ .iterate = true }) };
    return .{ .inner = try std.Io.Dir.cwd().openDir(io(), path, .{ .iterate = true }) };
}

// ── Environment / process ───────────────────────────────────────────

pub fn getenv(key: []const u8) ?[:0]const u8 {
    if (comptime !is_zig_016) return std.posix.getenv(key);
    // 0.16 removed std.posix.getenv; issy always links libc on its
    // supported targets, so scan the libc environ block directly.
    var i: usize = 0;
    while (std.c.environ[i]) |entry_z| : (i += 1) {
        const entry = std.mem.sliceTo(entry_z, 0);
        if (entry.len > key.len and entry[key.len] == '=' and
            std.mem.eql(u8, entry[0..key.len], key))
        {
            return entry[key.len + 1 .. :0];
        }
    }
    return null;
}

pub fn getcwd(buffer: []u8) ![]u8 {
    if (comptime !is_zig_016) return std.posix.getcwd(buffer);
    const n = try std.process.currentPath(io(), buffer);
    return buffer[0..n];
}

pub fn selfExePath(buffer: []u8) ![]u8 {
    if (comptime !is_zig_016) return std.fs.selfExePath(buffer);
    const n = try std.process.executablePath(io(), buffer);
    return buffer[0..n];
}

pub fn nowNanos() i128 {
    if (comptime !is_zig_016) return std.time.nanoTimestamp();
    return @as(i128, std.Io.Timestamp.now(io(), .real).nanoseconds);
}

/// O_NOFOLLOW open used by the swap-file autosave. 0.16 dropped
/// std.posix.open, so that side goes through libc directly.
pub fn openSwapNoFollow(path: []const u8) !File {
    const flags: std.posix.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true };
    if (comptime !is_zig_016) {
        const fd = try std.posix.open(path, flags, 0o600);
        return .{ .handle = fd };
    }
    var path_z: [max_path_bytes]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    const fd = std.c.open(path_z[0..path.len :0], @bitCast(flags), @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    return .{ .handle = fd };
}

/// Re-create the process-wide Io instance in a freshly forked child
/// (0.16 only; a no-op on 0.15, which has no Io).
///
/// `std.Io.Threaded` is a thread pool. Only the calling thread survives
/// fork(2), so a child that inherited an initialized pool holds a
/// structure describing workers that no longer exist. Today that is
/// harmless — 0.16.0's `Threaded.init` spawns no threads up front, and
/// the http/net/dir paths the update worker uses never enter the
/// async vtable that would spawn any — but the invariant is invisible
/// and one stdlib change away from breaking: a threaded resolver or a
/// concurrent connect would leave the child enqueued on a run queue
/// nobody drains, blocking until the worker's SIGALRM kills it. That
/// failure mode is silent (auto-update simply stops working), so guard
/// it rather than depend on stdlib internals.
///
/// Deliberately does NOT deinit the inherited instance: that would try
/// to join worker threads the child does not have.
pub fn resetIoAfterFork() void {
    if (comptime !is_zig_016) return;
    threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    threaded_state = .ready;
}

/// Fill `buf` with random bytes (used for temp-name uniqueness; O_EXCL
/// provides the actual collision safety). 0.16 removed the ambient
/// std.crypto.random in favor of the Io interface's csprng.
pub fn randomBytes(buf: []u8) void {
    if (comptime !is_zig_016) {
        std.crypto.random.bytes(buf);
        return;
    }
    io().random(buf);
}

/// Best-effort fsync of the directory containing `path`, making a
/// rename that just landed there durable. Failures are deliberately
/// ignored: some filesystems refuse directory fsync (EINVAL), and once
/// the file data itself is synced, losing the rename on a crash is
/// strictly better than failing a save whose bytes are already safe.
pub fn syncDirOf(path: []const u8) void {
    const dir_path = std.fs.path.dirname(path) orelse ".";
    const flags: std.posix.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true };
    if (comptime !is_zig_016) {
        const fd = std.posix.open(dir_path, flags, 0) catch return;
        defer std.posix.close(fd);
        _ = std.c.fsync(fd);
        return;
    }
    var dir_z: [max_path_bytes]u8 = undefined;
    if (dir_path.len >= dir_z.len) return;
    @memcpy(dir_z[0..dir_path.len], dir_path);
    dir_z[dir_path.len] = 0;
    const fd = std.c.open(dir_z[0..dir_path.len :0], @bitCast(flags), @as(std.c.mode_t, 0));
    if (fd < 0) return;
    _ = std.c.fsync(fd);
    _ = std.c.close(fd);
}

pub fn nowMillis() i64 {
    if (comptime !is_zig_016) return std.time.milliTimestamp();
    return std.Io.Timestamp.now(io(), .real).toMilliseconds();
}

/// access(2) with W_OK — "is this path writable by us".
pub fn accessWritable(path: []const u8) !void {
    if (comptime !is_zig_016) return std.posix.access(path, std.posix.W_OK);
    var path_z: [max_path_bytes]u8 = undefined;
    if (path.len >= path_z.len) return error.NameTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    if (std.c.access(path_z[0..path.len :0], std.posix.W_OK) != 0) return error.AccessDenied;
}

/// Replace the process image. Never returns on success.
pub fn execv(allocator: std.mem.Allocator, argv: []const []const u8) anyerror!noreturn {
    if (comptime !is_zig_016) {
        return std.process.execv(allocator, argv);
    }
    // 0.16 dropped std.process.execv; go through libc execve.
    const argv_z = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |arg, i| {
        argv_z[i] = (try allocator.dupeZ(u8, arg)).ptr;
    }
    _ = std.c.execve(argv_z[0].?, argv_z.ptr, @ptrCast(std.c.environ));
    return error.ExecFailed;
}

pub fn isatty(fd: std.posix.fd_t) bool {
    return std.c.isatty(fd) != 0;
}

// ── Tests ───────────────────────────────────────────────────────────

test "getenv finds PATH and misses garbage" {
    try std.testing.expect(getenv("PATH") != null);
    try std.testing.expect(getenv("ISSY_DEFINITELY_NOT_SET_XYZZY") == null);
}

test "create/stat/read/delete round-trip" {
    // Unique per process: this file runs in several test compilation
    // units concurrently under `zig build test`.
    var path_buf: [64]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "/tmp/.fsx-test-roundtrip.{d}", .{std.c.getpid()});
    {
        const f = try createFile(path, .{ .mode = 0o600 });
        defer f.close();
        try f.writeAll("hello fsx");
    }
    const st = try statFile(path);
    try std.testing.expectEqual(@as(u64, 9), st.size);
    try std.testing.expectEqual(Kind.file, st.kind);

    var buf: [32]u8 = undefined;
    const f = try openFile(path);
    const n = try f.readAll(&buf);
    f.close();
    try std.testing.expectEqualStrings("hello fsx", buf[0..n]);

    try deleteFile(path);
    try std.testing.expectError(error.FileNotFound, statFile(path));
}

test "getcwd returns an absolute path" {
    var buf: [max_path_bytes]u8 = undefined;
    const cwd = try getcwd(&buf);
    try std.testing.expect(cwd.len > 0 and cwd[0] == '/');
}
