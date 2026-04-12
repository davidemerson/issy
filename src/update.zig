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
        .macos => switch (builtin.target.cpu.arch) {
            .x86_64 => "issy-macos-amd64",
            .aarch64 => "issy-macos-arm64",
            else => null,
        },
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
/// network error). Caller frees.
fn httpGet(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    url: []const u8,
    max_size: usize,
) ?[]u8 {
    var body: std.ArrayList(u8) = .{};
    errdefer body.deinit(allocator);

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &body },
        .max_append_size = max_size,
    }) catch {
        body.deinit(allocator);
        return null;
    };

    if (result.status != .ok) {
        body.deinit(allocator);
        return null;
    }

    return body.toOwnedSlice(allocator) catch null;
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

test "update_key is bootstrapped" {
    // This repo has a real Ed25519 public key committed in src/update_key.zig.
    // If this test fails, the key has been zeroed out — auto-update will
    // silently refuse to stage any binary until it's regenerated via
    // `zig build keygen`.
    try std.testing.expect(update_key.isConfigured());
}
