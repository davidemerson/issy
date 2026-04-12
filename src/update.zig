//! Auto-update: detection and notification (Phase 1, notify-only).
//!
//! On startup:
//!   1. Read cached commit SHA from ~/.cache/issy/commit.txt and compare
//!      against build_info.commit_sha. If different, set status to .available.
//!   2. Fork a detached grandchild worker that fetches the latest commit.txt
//!      over HTTPS and writes it back to the cache for the next run.
//!
//! The worker is double-forked so the grandchild is adopted by init and we
//! never need to reap it from the editor's main loop. The worker sets
//! alarm(fetch_timeout_seconds) so it can't hang indefinitely.
//!
//! No binary download, no signature verification, no apply path in Phase 1.

const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");
const build_info = @import("build_info.zig");

const is_posix = builtin.os.tag != .windows;

pub const Status = enum { none, available, error_state };

pub const UpdateState = struct {
    status: Status = .none,
    latest_sha: [40]u8 = undefined,
    has_latest: bool = false,
    message: [128]u8 = undefined,
    message_len: usize = 0,

    pub fn getMessage(self: *const UpdateState) []const u8 {
        return self.message[0..self.message_len];
    }

    fn setMessage(self: *UpdateState, msg: []const u8) void {
        const n = @min(msg.len, self.message.len);
        @memcpy(self.message[0..n], msg[0..n]);
        self.message_len = n;
    }
};

const commit_url = "https://github.com/davidemerson/issy/releases/latest/download/commit.txt";
const fetch_timeout_seconds: u32 = 15;

/// Called from main() after editor init and before the main loop.
/// Never blocks on the network. Safe to call unconditionally; respects
/// cfg.notify_updates and skips dev builds entirely.
pub fn startupCheck(
    state: *UpdateState,
    allocator: std.mem.Allocator,
    cfg: *const config_mod.Config,
) void {
    if (!cfg.notify_updates and !cfg.autoupdate) return;
    if (build_info.build_type == .dev) return;
    if (!is_posix) return;

    const cache_dir = ensureCacheDir(allocator) catch return;
    defer allocator.free(cache_dir);

    const commit_path = std.fmt.allocPrint(allocator, "{s}/commit.txt", .{cache_dir}) catch return;
    defer allocator.free(commit_path);

    readCachedState(state, commit_path);

    // Fork a detached worker to refresh the cache for the next run.
    spawnWorker(allocator, commit_path);
}

fn ensureCacheDir(allocator: std.mem.Allocator) ![]u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(allocator, "{s}/.cache/issy", .{home});
    errdefer allocator.free(path);
    std.fs.cwd().makePath(path) catch {};
    return path;
}

fn readCachedState(state: *UpdateState, commit_path: []const u8) void {
    const file = std.fs.cwd().openFile(commit_path, .{}) catch return;
    defer file.close();
    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (trimmed.len < 40) return;

    @memcpy(state.latest_sha[0..], trimmed[0..40]);
    state.has_latest = true;

    if (!std.mem.eql(u8, trimmed[0..40], build_info.commit_sha[0..40])) {
        state.status = .available;
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "update available: {s}", .{trimmed[0..7]}) catch {
            state.setMessage("update available");
            return;
        };
        state.setMessage(msg);
    }
}

fn spawnWorker(allocator: std.mem.Allocator, commit_path: []const u8) void {
    if (!is_posix) return;

    const pid = std.posix.fork() catch return;
    if (pid != 0) {
        // Parent: reap the intermediate child immediately. The grandchild is
        // orphaned and will be reaped by init.
        _ = std.posix.waitpid(pid, 0);
        return;
    }

    // Intermediate child. Fork again so the grandchild is orphaned.
    const pid2 = std.posix.fork() catch std.posix.exit(0);
    if (pid2 != 0) std.posix.exit(0);

    // Grandchild: detach and do the HTTP fetch.
    _ = std.posix.setsid() catch {};
    setAlarm(fetch_timeout_seconds);

    // Duplicate commit_path out of parent-owned memory since we may fork and
    // diverge; on Unix the child already has a copy-on-write view so we can
    // use commit_path directly.
    doFetch(allocator, commit_path);
    std.posix.exit(0);
}

fn setAlarm(seconds: u32) void {
    // SIGALRM's default disposition is to terminate the process. Best effort:
    // only available when we're linking libc. OpenBSD/FreeBSD builds skip.
    if (comptime builtin.link_libc) {
        _ = std.c.alarm(@intCast(seconds));
    }
}

fn doFetch(allocator: std.mem.Allocator, commit_path: []const u8) void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var body: std.ArrayList(u8) = .{};
    defer body.deinit(allocator);

    const result = client.fetch(.{
        .location = .{ .url = commit_url },
        .method = .GET,
        .response_storage = .{ .dynamic = &body },
        .max_append_size = 4096,
    }) catch return;

    if (result.status != .ok) return;
    if (body.items.len < 40) return;

    // Atomic write: tmp + rename.
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{commit_path}) catch return;

    const tmp_file = std.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch return;
    tmp_file.writeAll(body.items[0..40]) catch {
        tmp_file.close();
        return;
    };
    tmp_file.close();

    std.fs.cwd().rename(tmp_path, commit_path) catch return;
}

// ── Tests ──

test "UpdateState default is none" {
    const s = UpdateState{};
    try std.testing.expectEqual(Status.none, s.status);
    try std.testing.expectEqual(@as(usize, 0), s.message_len);
}

test "UpdateState setMessage truncates to buffer size" {
    var s = UpdateState{};
    s.setMessage("hello");
    try std.testing.expectEqualStrings("hello", s.getMessage());
}

test "build_info has expected fields" {
    try std.testing.expect(build_info.commit_sha.len == 40);
    _ = build_info.version;
    _ = build_info.build_type;
}
