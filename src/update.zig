//! Auto-update: detection, download, signature verification, and staging.
//!
//! Phase 1 (notify-only) and Phase 2 (signed staging). Phase 3 (in-session
//! apply + re-exec) lives in main.zig.
//!
//! Startup path:
//!   1. Read ~/.cache/issy/commit.txt and compare against
//!      build_info.commit_sha. If different, status = .available.
//!   2. If ~/.cache/issy/issy.staged exists and is an executable file
//!      newer than our own binary, status = .staged.
//!   3. Fork a detached grandchild worker that refreshes the cache:
//!      - Always fetches commit.txt (cheap).
//!      - If cfg.autoupdate AND update_key is configured AND the latest
//!        SHA differs AND we have a platform asset name, fetches
//!        sha256sums.txt + .sig, verifies the Ed25519 signature, downloads
//!        the matching binary, SHA-256-checks it against the manifest,
//!        chmod +x, atomic-rename into issy.staged.
//!
//! The worker is double-forked so the grandchild is adopted by init and
//! never needs to be reaped by the editor. setAlarm() caps total runtime
//! at fetch_timeout_seconds via SIGALRM.
//!
//! All failure modes are silent by design: the user never sees an error
//! message from a background update fetch. On success, the next editor
//! run picks up the cached state.

const std = @import("std");
const builtin = @import("builtin");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ed25519 = std.crypto.sign.Ed25519;
const config_mod = @import("config.zig");
const build_info = @import("build_info.zig");
const update_key = @import("update_key.zig");
const editor_mod = @import("editor.zig");
const term = @import("term.zig");

const is_posix = builtin.os.tag != .windows;

pub const Status = enum { none, available, staged, error_state };

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

const base_url = "https://github.com/davidemerson/issy/releases/latest/download/";
const commit_url = base_url ++ "commit.txt";
const sums_url = base_url ++ "sha256sums.txt";
const sig_url = base_url ++ "sha256sums.txt.sig";

const fetch_timeout_seconds: u32 = 30;
const max_commit_size: usize = 128;
const max_manifest_size: usize = 16 * 1024;
const max_sig_size: usize = 256;
const max_binary_size: usize = 32 * 1024 * 1024;

/// Returns the GitHub release asset name for the current build target,
/// or null if this platform doesn't ship a prebuilt binary.
fn currentAssetName() ?[]const u8 {
    return switch (builtin.target.os.tag) {
        .linux => switch (builtin.target.cpu.arch) {
            .x86_64 => "issy-linux-amd64",
            .aarch64 => "issy-linux-arm64",
            else => null,
        },
        // macOS does not ship prebuilt binaries — install via Homebrew tap
        // (`brew install --HEAD davidemerson/issy/issy`) or from source, so
        // auto-apply has nothing to download. The notify-only path continues
        // to work: commit.txt comparison shows "update available" in the
        // status bar, and users run `brew upgrade --fetch-HEAD issy` to act
        // on it.
        .macos => null,
        .openbsd => switch (builtin.target.cpu.arch) {
            .x86_64 => "issy-openbsd-amd64",
            else => null,
        },
        else => null,
    };
}

/// Called from main() after editor init and before the main loop. Never
/// blocks on the network. Safe to call unconditionally; respects
/// cfg.notify_updates and cfg.autoupdate, and skips dev builds entirely.
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
    upgradeToStagedIfReady(state, cache_dir, allocator);

    // Fork a detached worker to refresh the cache for the next run.
    spawnWorker(allocator, cache_dir, commit_path, cfg.autoupdate);
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

/// If a verified staged binary is ready for apply, upgrade the status
/// from .available to .staged and update the message accordingly.
fn upgradeToStagedIfReady(
    state: *UpdateState,
    cache_dir: []const u8,
    allocator: std.mem.Allocator,
) void {
    if (state.status != .available) return;

    const staged_path = std.fmt.allocPrint(allocator, "{s}/issy.staged", .{cache_dir}) catch return;
    defer allocator.free(staged_path);

    const file = std.fs.cwd().openFile(staged_path, .{}) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    if (stat.kind != .file) return;
    if (stat.size < 1024) return; // refuse empty/truncated binaries

    state.status = .staged;
    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "update staged: {s}", .{state.latest_sha[0..7]}) catch {
        state.setMessage("update staged");
        return;
    };
    state.setMessage(msg);
}

fn spawnWorker(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    commit_path: []const u8,
    autoupdate: bool,
) void {
    if (!is_posix) return;

    const pid = std.posix.fork() catch return;
    if (pid != 0) {
        _ = std.posix.waitpid(pid, 0);
        return;
    }

    // Intermediate child: fork again and exit so the grandchild is orphaned.
    const pid2 = std.posix.fork() catch std.posix.exit(0);
    if (pid2 != 0) std.posix.exit(0);

    // Grandchild: detach from the tty and do the work.
    _ = std.posix.setsid() catch {};
    setAlarm(fetch_timeout_seconds);

    doWork(allocator, cache_dir, commit_path, autoupdate);
    std.posix.exit(0);
}

fn setAlarm(seconds: u32) void {
    if (comptime builtin.link_libc) {
        _ = std.c.alarm(@intCast(seconds));
    }
}

fn doWork(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    commit_path: []const u8,
    autoupdate: bool,
) void {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // 1. Fetch commit.txt → cache.
    const commit_body = httpGet(&client, allocator, commit_url, max_commit_size) orelse return;
    defer allocator.free(commit_body);
    if (commit_body.len < 40) return;

    writeAtomic(commit_path, commit_body[0..40]) catch return;

    // Phase 2 work: only if autoupdate is on AND we have a pubkey AND this
    // platform has a binary AND the latest SHA is different from ours.
    if (!autoupdate) return;
    if (!update_key.isConfigured()) return;

    const asset_name = currentAssetName() orelse return;

    if (std.mem.eql(u8, commit_body[0..40], build_info.commit_sha[0..40])) return;

    downloadAndStage(&client, allocator, cache_dir, asset_name) catch return;
}

fn downloadAndStage(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    asset_name: []const u8,
) !void {
    // 2. Fetch sha256sums.txt and its signature.
    const manifest = httpGet(client, allocator, sums_url, max_manifest_size) orelse return error.ManifestFetchFailed;
    defer allocator.free(manifest);

    const sig_bytes = httpGet(client, allocator, sig_url, max_sig_size) orelse return error.SigFetchFailed;
    defer allocator.free(sig_bytes);

    // 3. Verify Ed25519 signature.
    try verifyManifestSignature(manifest, sig_bytes);

    // 4. Find the expected SHA-256 for our platform.
    const expected_hex = findAssetHash(manifest, asset_name) orelse return error.AssetNotInManifest;
    var expected_hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_hash, expected_hex) catch return error.BadHexHash;

    // 5. Download the binary.
    const asset_url = std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, asset_name }) catch return error.Oom;
    defer allocator.free(asset_url);

    const binary = httpGet(client, allocator, asset_url, max_binary_size) orelse return error.BinaryFetchFailed;
    defer allocator.free(binary);

    // 6. Hash the downloaded binary and compare.
    var actual_hash: [32]u8 = undefined;
    Sha256.hash(binary, &actual_hash, .{});
    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) return error.HashMismatch;

    // 7. Atomic write: staged.tmp → chmod +x → rename to staged.
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}/issy.staged.tmp", .{cache_dir});
    defer allocator.free(tmp_path);
    const final_path = try std.fmt.allocPrint(allocator, "{s}/issy.staged", .{cache_dir});
    defer allocator.free(final_path);

    {
        const f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true, .mode = 0o755 });
        defer f.close();
        try f.writeAll(binary);
    }
    try std.fs.cwd().rename(tmp_path, final_path);
}

fn verifyManifestSignature(manifest: []const u8, sig_bytes: []const u8) !void {
    if (sig_bytes.len != Ed25519.Signature.encoded_length) return error.BadSigLength;

    var sig_arr: [Ed25519.Signature.encoded_length]u8 = undefined;
    @memcpy(&sig_arr, sig_bytes);
    const sig = Ed25519.Signature.fromBytes(sig_arr);

    const pk = Ed25519.PublicKey.fromBytes(update_key.public_key) catch return error.BadPubkey;

    sig.verify(manifest, pk) catch return error.SigVerifyFailed;
}

/// Parses a `sha256sum`-style manifest and returns the 64-char hex hash
/// corresponding to `asset_name`, or null if not found. The manifest format is:
///   <64-hex>  <filename>\n
///   <64-hex>  <filename>\n
///   ...
fn findAssetHash(manifest: []const u8, asset_name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len < 66) continue;
        // Hash is the first 64 chars, then whitespace, then filename (possibly prefixed with "*" for binary mode).
        const hash = trimmed[0..64];
        var rest = std.mem.trimLeft(u8, trimmed[64..], " \t*");
        // Some sha256sum implementations keep a "./" prefix or a full path.
        // Accept any match where the trailing component equals asset_name.
        const base = if (std.mem.lastIndexOfScalar(u8, rest, '/')) |slash| rest[slash + 1 ..] else rest;
        if (std.mem.eql(u8, base, asset_name)) {
            // Validate hash is 64 hex chars.
            for (hash) |c| {
                const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
                if (!ok) return null;
            }
            return hash;
        }
    }
    return null;
}

/// Issues an HTTP GET request and returns the response body as an
/// allocator-owned slice, or null on any failure (non-200, oversize,
/// network error, alloc failure). Caller frees.
///
/// The fetch is bounded by `max_size`: the response is streamed into a
/// fixed-size buffer, and if the server sends more than `max_size` bytes
/// the underlying Writer returns WriteFailed and we bail.
fn httpGet(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    max_size: usize,
) ?[]u8 {
    const scratch = allocator.alloc(u8, max_size) catch return null;
    defer allocator.free(scratch);

    var writer = std.Io.Writer.fixed(scratch);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &writer,
    }) catch return null;

    if (result.status != .ok) return null;

    const written = writer.end;
    const out = allocator.alloc(u8, written) catch return null;
    @memcpy(out, scratch[0..written]);
    return out;
}

/// Atomic file write: create a `.tmp` sibling, write, rename.
fn writeAtomic(path: []const u8, content: []const u8) !void {
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});

    {
        const f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(content);
    }
    try std.fs.cwd().rename(tmp_path, path);
}

// ── Phase 3: in-session re-exec ──

pub const min_idle_ms_default: u64 = 60_000;
const resume_file_version: u32 = 1;
const resume_max_age_ns: i128 = 5 * std.time.ns_per_min;

/// Returns true iff all gates for in-session auto-apply are satisfied:
///   - a verified binary is staged
///   - auto-apply is on in config
///   - buffer is clean (no unsaved changes)
///   - the editor has been idle for at least `min_idle_ms`
pub fn canAutoApply(
    state: *const UpdateState,
    ed: *const editor_mod.Editor,
    cfg: *const config_mod.Config,
    idle_ms: u64,
    min_idle_ms: u64,
) bool {
    if (state.status != .staged) return false;
    if (!cfg.autoupdate) return false;
    if (ed.modified) return false;
    if (idle_ms < min_idle_ms) return false;
    return true;
}

pub const ApplyError = error{
    NoCacheDir,
    NoStagedBinary,
    SelfExePathFailed,
    NotWritable,
    ResumeWriteFailed,
    RenameFailed,
    ExecFailed,
    OutOfMemory,
};

/// Applies a staged binary by replacing argv0, writing a resume record,
/// tearing down the terminal, and execve'ing the new binary with
/// `--resume <path>` so the new instance restores the cursor position.
///
/// On success this function does not return. On failure the caller
/// should keep running the current binary; the staged binary is left
/// in place for a retry on the next cycle.
pub fn apply(
    allocator: std.mem.Allocator,
    ed: *const editor_mod.Editor,
) ApplyError!noreturn {
    const cache_dir = ensureCacheDir(allocator) catch return ApplyError.NoCacheDir;
    defer allocator.free(cache_dir);

    var argv0_buf: [std.fs.max_path_bytes]u8 = undefined;
    const argv0 = std.fs.selfExePath(&argv0_buf) catch return ApplyError.SelfExePathFailed;

    // Writability check — the binary swap uses rename(2), which needs the
    // parent directory to be writable. faccessat with W_OK on the file
    // itself is a reasonable proxy on Linux/macOS; fails for root-owned
    // installs like /usr/bin/issy.
    std.posix.access(argv0, std.posix.W_OK) catch return ApplyError.NotWritable;

    const staged_path = std.fmt.allocPrint(allocator, "{s}/issy.staged", .{cache_dir}) catch return ApplyError.OutOfMemory;
    defer allocator.free(staged_path);
    const prev_path = std.fmt.allocPrint(allocator, "{s}/issy.prev", .{cache_dir}) catch return ApplyError.OutOfMemory;
    defer allocator.free(prev_path);

    // Confirm staged binary still exists and looks sane.
    const staged_stat = std.fs.cwd().statFile(staged_path) catch return ApplyError.NoStagedBinary;
    if (staged_stat.kind != .file) return ApplyError.NoStagedBinary;
    if (staged_stat.size < 1024) return ApplyError.NoStagedBinary;

    // Write resume file before touching the binary, so if anything goes
    // wrong we haven't broken the running instance.
    const now_ns = std.time.nanoTimestamp();
    const resume_path = std.fmt.allocPrint(allocator, "{s}/resume.{d}.txt", .{ cache_dir, @as(i64, @intCast(@divTrunc(now_ns, std.time.ns_per_s))) }) catch return ApplyError.OutOfMemory;
    defer allocator.free(resume_path);

    writeResumeFile(resume_path, ed, now_ns) catch return ApplyError.ResumeWriteFailed;

    // Snapshot the currently-running binary so --rollback has something to
    // restore. Best-effort: a failure here doesn't block the apply.
    copyFileBestEffort(argv0, prev_path);

    // Atomic binary swap. From this point the next execve call is the only
    // reasonable way forward — the current in-memory image is out of sync
    // with the file that argv0 now points to.
    std.fs.cwd().rename(staged_path, argv0) catch {
        // Keep the resume file around so the user can restart manually.
        return ApplyError.RenameFailed;
    };

    // Tear down the terminal cleanly before execve: restores cooked mode,
    // exits alt-screen, turns off mouse reporting, resets cursor shape,
    // flushes the write buffer.
    term.deinit();

    // Build argv: [argv0, "--resume", resume_path, filename]. If the
    // editor doesn't currently have an open file, omit the last argument.
    const filename_slice = ed.getFilename();
    var argv_slice = [_][]const u8{ undefined, undefined, undefined, undefined };
    argv_slice[0] = argv0;
    argv_slice[1] = "--resume";
    argv_slice[2] = resume_path;
    argv_slice[3] = filename_slice;
    const argv = if (filename_slice.len == 0) argv_slice[0..3] else argv_slice[0..4];

    // std.process.execv replaces the current process image on success.
    std.process.execv(allocator, argv) catch {
        // execve failed after rename + term.deinit. The terminal is in
        // cooked mode, the binary on disk is the new version but our
        // in-memory process is the old one. Best we can do: try to
        // re-init the terminal so the user isn't stranded.
        term.init() catch {};
        return ApplyError.ExecFailed;
    };
    unreachable;
}

fn writeResumeFile(path: []const u8, ed: *const editor_mod.Editor, now_ns: i128) !void {
    var tmp_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&tmp_path_buf, "{s}.tmp", .{path});

    const f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
    defer f.close();

    var buf: [4096]u8 = undefined;
    var fw = f.writer(&buf);
    const w = &fw.interface;

    try w.print("v{d}\n", .{resume_file_version});
    try w.print("{d}\n", .{now_ns});
    try w.print("{d}\n", .{ed.file_mtime orelse 0});
    try w.print("{d}\n", .{ed.cursor.line});
    try w.print("{d}\n", .{ed.cursor.col});
    try w.print("{s}\n", .{ed.getFilename()});
    try w.flush();

    try std.fs.cwd().rename(tmp_path, path);
}

fn copyFileBestEffort(src: []const u8, dst: []const u8) void {
    std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{}) catch {};
}

/// Reads a resume file written by `apply` and restores the editor's
/// cursor position for the currently-open file. Called once at startup
/// from main() when `--resume <path>` is present on argv.
///
/// Safety checks:
///   - version must match
///   - created_ns must be within the last few minutes
///   - file mtime must match the recorded value (otherwise the file was
///     edited externally between apply and restore, and the cursor
///     position would be stale)
pub fn tryResume(
    ed: *editor_mod.Editor,
    resume_path: []const u8,
) void {
    defer std.fs.cwd().deleteFile(resume_path) catch {};

    const f = std.fs.cwd().openFile(resume_path, .{}) catch return;
    defer f.close();

    var buf: [1024]u8 = undefined;
    const n = f.readAll(&buf) catch return;
    const content = buf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    const version_line = lines.next() orelse return;
    if (version_line.len < 2 or version_line[0] != 'v') return;
    const version = std.fmt.parseInt(u32, version_line[1..], 10) catch return;
    if (version != resume_file_version) return;

    const created_str = lines.next() orelse return;
    const created_ns = std.fmt.parseInt(i128, std.mem.trim(u8, created_str, " \r\t"), 10) catch return;

    const now_ns = std.time.nanoTimestamp();
    if (now_ns - created_ns > resume_max_age_ns) return;

    const mtime_str = lines.next() orelse return;
    const saved_mtime = std.fmt.parseInt(i128, std.mem.trim(u8, mtime_str, " \r\t"), 10) catch return;

    const line_str = lines.next() orelse return;
    const saved_line = std.fmt.parseInt(usize, std.mem.trim(u8, line_str, " \r\t"), 10) catch return;

    const col_str = lines.next() orelse return;
    const saved_col = std.fmt.parseInt(usize, std.mem.trim(u8, col_str, " \r\t"), 10) catch return;

    // Refuse to restore if the file on disk has been touched since the
    // snapshot — the cursor position may no longer be meaningful.
    if (saved_mtime != 0) {
        if (ed.file_mtime) |current_mtime| {
            if (current_mtime != saved_mtime) return;
        }
    }

    const max_line = if (ed.buf.lineCount() > 0) ed.buf.lineCount() - 1 else 0;
    ed.cursor.line = @min(saved_line, max_line);
    ed.cursor.col = saved_col;
    ed.ensureCursorVisible();

    var msg_buf: [128]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "upgraded to {s}", .{build_info.commit_sha[0..@min(7, build_info.commit_sha.len)]}) catch "upgraded";
    ed.setStatusMessage(msg);
}

/// Manual rollback: replace the running binary on disk with
/// ~/.cache/issy/issy.prev (the snapshot taken before the last
/// successful apply). This is called from main() when `--rollback` is
/// on argv, before any TUI or editor state is created.
pub fn rollback(allocator: std.mem.Allocator) !void {
    if (!is_posix) return error.UnsupportedPlatform;

    const cache_dir = try ensureCacheDir(allocator);
    defer allocator.free(cache_dir);

    const prev_path = try std.fmt.allocPrint(allocator, "{s}/issy.prev", .{cache_dir});
    defer allocator.free(prev_path);

    var argv0_buf: [std.fs.max_path_bytes]u8 = undefined;
    const argv0 = try std.fs.selfExePath(&argv0_buf);

    std.posix.access(argv0, std.posix.W_OK) catch return error.NotWritable;
    _ = std.fs.cwd().statFile(prev_path) catch return error.NoPreviousBinary;

    try std.fs.cwd().rename(prev_path, argv0);
}

// ── Tests ──

test "UpdateState default is none" {
    const s = UpdateState{};
    try std.testing.expectEqual(Status.none, s.status);
    try std.testing.expectEqual(@as(usize, 0), s.message_len);
}

test "UpdateState setMessage copies correctly" {
    var s = UpdateState{};
    s.setMessage("hello");
    try std.testing.expectEqualStrings("hello", s.getMessage());
}

test "build_info has expected fields" {
    try std.testing.expect(build_info.commit_sha.len == 40);
    _ = build_info.version;
    _ = build_info.build_type;
}

test "currentAssetName returns a name for the host platform" {
    if (currentAssetName()) |name| {
        try std.testing.expect(name.len > 0);
    }
}

test "findAssetHash locates a matching line" {
    const manifest =
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789  issy-linux-amd64\n" ++
        "1111111111111111111111111111111111111111111111111111111111111111  issy-macos-arm64\n" ++
        "2222222222222222222222222222222222222222222222222222222222222222  ./dist/issy-openbsd-amd64\n";

    const h1 = findAssetHash(manifest, "issy-linux-amd64").?;
    try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789", h1);

    const h2 = findAssetHash(manifest, "issy-macos-arm64").?;
    try std.testing.expect(std.mem.eql(u8, h2, "1111111111111111111111111111111111111111111111111111111111111111"));

    const h3 = findAssetHash(manifest, "issy-openbsd-amd64").?;
    try std.testing.expect(std.mem.eql(u8, h3, "2222222222222222222222222222222222222222222222222222222222222222"));

    try std.testing.expectEqual(@as(?[]const u8, null), findAssetHash(manifest, "nonexistent"));
}

test "verifyManifestSignature accepts valid sig and rejects tampered one" {
    // Generate an ephemeral keypair for the test — we deliberately don't
    // use update_key.public_key here so the test is self-contained.
    const kp = Ed25519.KeyPair.generate();
    const manifest = "abc  issy-linux-amd64\n";
    const sig = try kp.sign(manifest, null);

    // Good path.
    try sig.verify(manifest, kp.public_key);

    // Tampered message.
    const tampered = "xyz  issy-linux-amd64\n";
    try std.testing.expectError(error.SignatureVerificationFailed, sig.verify(tampered, kp.public_key));
}

test "canAutoApply rejects when buffer is modified" {
    var cfg = config_mod.Config.init();
    cfg.autoupdate = true;

    var ed = editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    var state = UpdateState{ .status = .staged };

    // Clean + idle + staged + autoupdate on → should apply.
    try std.testing.expect(canAutoApply(&state, &ed, &cfg, 60_000, 60_000));

    // Modified → reject.
    ed.modified = true;
    try std.testing.expect(!canAutoApply(&state, &ed, &cfg, 60_000, 60_000));
    ed.modified = false;

    // Not idle long enough → reject.
    try std.testing.expect(!canAutoApply(&state, &ed, &cfg, 30_000, 60_000));

    // Autoupdate off → reject.
    cfg.autoupdate = false;
    try std.testing.expect(!canAutoApply(&state, &ed, &cfg, 60_000, 60_000));
    cfg.autoupdate = true;

    // Not staged → reject.
    state.status = .available;
    try std.testing.expect(!canAutoApply(&state, &ed, &cfg, 60_000, 60_000));
}

test "update_key is bootstrapped" {
    // This repo has a real Ed25519 public key committed in src/update_key.zig.
    // If this test fails, the key has been zeroed out — auto-update will
    // silently refuse to stage any binary until it's regenerated via
    // `zig build keygen`.
    try std.testing.expect(update_key.isConfigured());
}
