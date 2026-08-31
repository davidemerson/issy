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
const fsx = @import("fsx.zig");
const builtin = @import("builtin");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Ed25519 = std.crypto.sign.Ed25519;
const config_mod = @import("config.zig");
const build_info = @import("build_info.zig");
const update_key = @import("update_key.zig");
const update_config = @import("update_config.zig");
const editor_mod = @import("editor.zig");
const term = @import("term.zig");

pub const Status = enum { none, available, staged, error_state };

pub const UpdateState = struct {
    status: Status = .none,
    latest_sha: [40]u8 = undefined,
    /// Commit timestamp of the advertised release, 0 if the cache
    /// predates the two-field commit.txt format or is unparseable.
    latest_epoch: u64 = 0,
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

// The real origin. update_config.base_url_override is null in every
// normally-built binary (build.zig rewrites that file on each configure),
// so this folds at comptime and no override survives into a release.
const default_base_url = "https://github.com/davidemerson/issy/releases/latest/download/";
const base_url = update_config.base_url_override orelse default_base_url;
const commit_url = base_url ++ "commit.txt";
const sums_url = base_url ++ "sha256sums.txt";
const sig_url = base_url ++ "sha256sums.txt.sig";

const fetch_timeout_seconds: u32 = 30;
const max_commit_size: usize = 128;
const max_manifest_size: usize = 16 * 1024;
const max_sig_size: usize = 256;
const max_binary_size: usize = 32 * 1024 * 1024;

// Signed-manifest header lines written by CI (inside the signed
// content, so they can't be forged without the signing key):
//   `# issy-commit: <sha>`          binds the manifest to its release
//   `# issy-manifest-epoch: <ts>`   monotonic anti-rollback counter
const commit_header = "# issy-commit:";
const epoch_header = "# issy-manifest-epoch:";

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
        // (`brew install davidemerson/issy/issy`, or `--HEAD` for main) or
        // from source, so auto-apply has nothing to download. The notify-only
        // path continues to work: commit.txt comparison shows "update
        // available" in the status bar, and users run `brew upgrade issy`
        // (or `brew upgrade --fetch-HEAD issy` for HEAD installs) to act on
        // it.
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
    const home = fsx.getenv("HOME") orelse return error.NoHome;
    const path = try std.fmt.allocPrint(allocator, "{s}/.cache/issy", .{home});
    errdefer allocator.free(path);
    fsx.makePath(path) catch {};
    return path;
}

/// The cache records the latest release as "<40 hex sha>[ <epoch>]".
/// The epoch is what lets us tell *newer* from merely *different*; a
/// cache written before the two-field format (or a malformed one)
/// yields 0 = unknown.
const CachedRelease = struct { sha: [40]u8, epoch: u64 };

fn parseCachedRelease(bytes: []const u8) ?CachedRelease {
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (trimmed.len < 40) return null;
    var out: CachedRelease = .{ .sha = undefined, .epoch = 0 };
    @memcpy(out.sha[0..], trimmed[0..40]);
    const rest = std.mem.trim(u8, trimmed[40..], " \t\r\n");
    if (rest.len > 0) out.epoch = std.fmt.parseInt(u64, rest, 10) catch 0;
    return out;
}

/// Should we tell the user an update is available?
///
/// When both timestamps are known, require the advertised release to be
/// strictly newer. Comparing SHAs for mere inequality — what this used
/// to do — advertises a DOWNGRADE after any manual upgrade (brew,
/// install.sh, a hand-copied binary), because the cache still names the
/// older release the last worker run saw.
///
/// Unknown epochs fail OPEN, falling back to inequality: a wrong status
/// line is the worst case, and a no-git tarball build would otherwise
/// never learn about updates at all. Installing is the decision that
/// fails closed — see verifyStagedBinary. Note this epoch arrives in an
/// UNSIGNED file, so it may gate a notification and must never gate an
/// install.
fn shouldNotify(our_sha: []const u8, our_epoch: u64, latest_sha: []const u8, latest_epoch: u64) bool {
    if (std.mem.eql(u8, our_sha[0..40], latest_sha[0..40])) return false;
    if (our_epoch != 0 and latest_epoch != 0) return latest_epoch > our_epoch;
    return true;
}

fn readCachedState(state: *UpdateState, commit_path: []const u8) void {
    const file = fsx.openFile(commit_path) catch return;
    defer file.close();
    var buf: [128]u8 = undefined;
    const n = file.readAll(&buf) catch return;
    const cached = parseCachedRelease(buf[0..n]) orelse return;

    state.latest_sha = cached.sha;
    state.latest_epoch = cached.epoch;

    if (shouldNotify(build_info.commit_sha[0..], build_info.commit_epoch, cached.sha[0..], cached.epoch)) {
        state.status = .available;
        var msg_buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "update available: {s}", .{cached.sha[0..7]}) catch {
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

    const file = fsx.openFile(staged_path) catch return;
    defer file.close();
    const stat = file.stat() catch return;
    if (stat.kind != .file) return;
    if (stat.size < 1024) return; // refuse empty/truncated binaries

    // Don't advertise (or later try to apply) a staged binary that isn't
    // strictly newer than us — apply() would refuse it anyway, and the
    // status bar would be claiming an upgrade that can never happen.
    const manifest_path = std.fmt.allocPrint(allocator, "{s}/sha256sums.txt", .{cache_dir}) catch return;
    defer allocator.free(manifest_path);
    const manifest = fsx.readFileAlloc(allocator, manifest_path, max_manifest_size) catch return;
    defer allocator.free(manifest);
    if (!applyOrderingOk(
        build_info.commit_epoch,
        manifestHeaderField(manifest, commit_header),
        manifestEpoch(manifest),
    )) return;

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
    // Raw libc process control: 0.16 dropped std.posix.fork/waitpid/
    // setsid/exit, and issy always links libc on its supported targets.
    const pid = std.c.fork();
    if (pid < 0) return;
    if (pid != 0) {
        var status: c_int = 0;
        _ = std.c.waitpid(pid, &status, 0);
        return;
    }

    // Intermediate child: fork again and exit so the grandchild is
    // orphaned (a failed second fork exits too — pid2 < 0).
    const pid2 = std.c.fork();
    if (pid2 != 0) std.c._exit(0);

    // Grandchild: detach from the tty and do the work. The parent has
    // already used fsx.io() (ensureCacheDir ran before us), so on 0.16
    // we inherited a thread pool whose workers didn't survive the fork —
    // replace it before any I/O. See fsx.resetIoAfterFork.
    _ = std.c.setsid();
    fsx.resetIoAfterFork();
    setAlarm(fetch_timeout_seconds);

    doWork(allocator, cache_dir, commit_path, autoupdate);
    std.c._exit(0);
}

fn setAlarm(seconds: u32) void {
    if (comptime builtin.link_libc) {
        _ = std.c.alarm(@intCast(seconds));
    }
}

/// True when the running binary's own path is writable — a necessary
/// condition for the rename(2) swap that applies an update.
///
/// NOTE: this asks whether the FILE is writable, while rename(2)
/// actually needs the containing DIRECTORY to be writable. The two
/// disagree in both directions (a root-owned file in a user-owned dir
/// can be replaced; a user-owned file in a root-owned dir cannot).
/// Keeping the file check preserves today's classification exactly;
/// switching to the dirname is a separate, deliberate behavior change
/// and is filed as a follow-up rather than smuggled in here.
fn selfIsWritable() bool {
    var buf: [fsx.max_path_bytes]u8 = undefined;
    const path = fsx.selfExePath(&buf) catch return false;
    fsx.accessWritable(path) catch return false;
    return true;
}

/// Is there any point downloading a release?
///
/// Pure so the whole decision tree is testable; `staged_matches_latest`
/// is threaded in because computing it needs the cache.
fn shouldStage(
    autoupdate: bool,
    key_configured: bool,
    has_asset: bool,
    writable: bool,
    is_newer: bool,
    staged_matches_latest: bool,
) bool {
    if (!autoupdate) return false;
    if (!key_configured) return false;
    if (!has_asset) return false;
    // Nothing we download here could ever be installed, so downloading
    // it is pure waste — this is the documented "notify-only" behavior
    // for root-owned installs, which previously re-fetched the whole
    // binary on every single launch.
    if (!writable) return false;
    if (!is_newer) return false;
    // Already staged and still current: don't re-download megabytes.
    // Bound to the COMMIT, not mere file existence, or a stale staged
    // binary would pin the user forever.
    if (staged_matches_latest) return false;
    return true;
}

/// Does a staged binary already correspond to `latest_sha`? Answered
/// from the cached signed manifest, which records the release it
/// describes in its commit header.
fn stagedMatchesLatest(allocator: std.mem.Allocator, cache_dir: []const u8, latest_sha: []const u8) bool {
    const staged_path = std.fmt.allocPrint(allocator, "{s}/issy.staged", .{cache_dir}) catch return false;
    defer allocator.free(staged_path);
    const st = fsx.statFile(staged_path) catch return false;
    if (st.kind != .file or st.size < 1024) return false;

    const manifest_path = std.fmt.allocPrint(allocator, "{s}/sha256sums.txt", .{cache_dir}) catch return false;
    defer allocator.free(manifest_path);
    const manifest = fsx.readFileAlloc(allocator, manifest_path, max_manifest_size) catch return false;
    defer allocator.free(manifest);

    const mc = manifestHeaderField(manifest, commit_header) orelse return false;
    if (mc.len < 40) return false;
    return std.mem.eql(u8, mc[0..40], latest_sha[0..40]);
}

fn doWork(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    commit_path: []const u8,
    autoupdate: bool,
) void {
    var client = if (comptime fsx.is_zig_016)
        std.http.Client{ .allocator = allocator, .io = fsx.io() }
    else
        std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // 1. Fetch commit.txt → cache.
    const commit_body = httpGet(&client, allocator, commit_url, max_commit_size) orelse return;
    defer allocator.free(commit_body);
    const latest = parseCachedRelease(commit_body) orelse return;

    // Persist the whole "<sha> <epoch>" record, trimmed — readCachedState
    // needs the epoch to tell newer from merely different.
    const record = std.mem.trim(u8, commit_body, " \t\r\n");
    writeAtomic(commit_path, record) catch return;

    // Phase 2 work. Every condition is in shouldStage() so the whole
    // decision is testable without a network or a fork.
    const asset_name = currentAssetName();
    const is_newer = shouldNotify(build_info.commit_sha[0..], build_info.commit_epoch, latest.sha[0..], latest.epoch);
    if (!shouldStage(
        autoupdate,
        update_key.isConfigured(),
        asset_name != null,
        selfIsWritable(),
        is_newer,
        stagedMatchesLatest(allocator, cache_dir, latest.sha[0..]),
    )) return;

    downloadAndStage(&client, allocator, cache_dir, asset_name.?, latest.sha[0..]) catch return;
}

fn downloadAndStage(
    client: *std.http.Client,
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    asset_name: []const u8,
    latest_commit: []const u8,
) !void {
    // 2. Fetch sha256sums.txt and its signature.
    const manifest = httpGet(client, allocator, sums_url, max_manifest_size) orelse return error.ManifestFetchFailed;
    defer allocator.free(manifest);

    const sig_bytes = httpGet(client, allocator, sig_url, max_sig_size) orelse return error.SigFetchFailed;
    defer allocator.free(sig_bytes);

    // 3. Verify Ed25519 signature.
    try verifyManifestSignature(manifest, sig_bytes);

    // 3a. Bind the manifest to the release we believe we're updating to.
    // The commit header is mandatory (CI always emits it): a signed
    // manifest with no commit binding, or one naming a different commit
    // than the fetched commit.txt, is rejected. Requiring it — rather
    // than only checking when present — closes the first-contact replay
    // window where a validly-signed pre-header release could be served.
    const mc = manifestHeaderField(manifest, commit_header) orelse return error.ManifestMissingCommit;
    if (mc.len < 40 or !std.mem.eql(u8, mc[0..40], latest_commit)) {
        return error.ManifestCommitMismatch;
    }

    // 3b. Anti-rollback: the epoch header is likewise mandatory. A
    // manifest with an epoch older than the newest we've ever accepted
    // is a replayed old release — authentic, but stale. Once an epoch
    // is seen, every future manifest must carry one that is >= it.
    const epoch_path = try std.fmt.allocPrint(allocator, "{s}/manifest_epoch.txt", .{cache_dir});
    defer allocator.free(epoch_path);
    const new_epoch = manifestEpoch(manifest) orelse return error.ManifestMissingEpoch;
    const cached_epoch = readCachedEpoch(epoch_path);
    if (!epochAllows(cached_epoch, new_epoch)) return error.RollbackDetected;

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

    // 7. Atomic write: unique staged.tmp → chmod +x → rename to staged.
    const final_path = try std.fmt.allocPrint(allocator, "{s}/issy.staged", .{cache_dir});
    defer allocator.free(final_path);
    var tmp_buf: [fsx.max_path_bytes + 48]u8 = undefined;
    const tmp_path = try uniqueTmpPath(&tmp_buf, final_path);

    var staged_ok = false;
    defer if (!staged_ok) fsx.deleteFile(tmp_path) catch {};
    {
        const f = try fsx.createFile(tmp_path, .{ .truncate = true, .mode = 0o755 });
        defer f.close();
        try f.writeAll(binary);
    }

    // Persist the verified manifest + signature so apply() can re-verify
    // the staged binary immediately before the swap (the staged file may
    // sit in the user-writable cache for days), then record the epoch
    // high-water mark and finally publish the staged binary.
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/sha256sums.txt", .{cache_dir});
    defer allocator.free(manifest_path);
    const sig_path = try std.fmt.allocPrint(allocator, "{s}/sha256sums.txt.sig", .{cache_dir});
    defer allocator.free(sig_path);
    try writeAtomic(manifest_path, manifest);
    try writeAtomic(sig_path, sig_bytes);
    {
        var epoch_buf: [32]u8 = undefined;
        const epoch_str = std.fmt.bufPrint(&epoch_buf, "{d}", .{new_epoch}) catch unreachable;
        try writeAtomic(epoch_path, epoch_str);
    }

    try fsx.rename(tmp_path, final_path);
    staged_ok = true;
}

/// Return the trimmed value following a `key` header line in the
/// manifest, or null when absent.
fn manifestHeaderField(manifest: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, t, key)) {
            return std.mem.trim(u8, t[key.len..], " \t");
        }
    }
    return null;
}

fn manifestEpoch(manifest: []const u8) ?u64 {
    const v = manifestHeaderField(manifest, epoch_header) orelse return null;
    return std.fmt.parseInt(u64, v, 10) catch null;
}

/// Anti-rollback decision: with no cached epoch anything is accepted
/// (first contact, or a pre-epoch release history). Once an epoch has
/// been cached, an incoming manifest must carry an epoch >= it —
/// including the case where the incoming manifest has no epoch at all,
/// which is exactly what a replayed pre-epoch release looks like.
fn epochAllows(cached: ?u64, incoming: ?u64) bool {
    const ce = cached orelse return true;
    const ne = incoming orelse return false;
    return ne >= ce;
}

fn readCachedEpoch(path: []const u8) ?u64 {
    const file = fsx.openFile(path) catch return null;
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = file.readAll(&buf) catch return null;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\r\n");
    return std.fmt.parseInt(u64, trimmed, 10) catch null;
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
        var rest = std.mem.trimStart(u8, trimmed[64..], " \t*");
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

/// Write a per-process-unique temp path for `path` into `buf` and return
/// the slice: `<path>.tmp.<pid>.<ns>`. Two concurrent editors or update
/// workers would otherwise truncate the same fixed `.tmp` sibling and
/// corrupt each other's in-flight writes before the rename.
fn uniqueTmpPath(buf: []u8, path: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{s}.tmp.{d}.{d}", .{ path, std.c.getpid(), fsx.nowNanos() });
}

/// Atomic file write: create a unique `.tmp` sibling, write, rename.
fn writeAtomic(path: []const u8, content: []const u8) !void {
    var tmp_path_buf: [fsx.max_path_bytes + 48]u8 = undefined;
    const tmp_path = try uniqueTmpPath(&tmp_path_buf, path);

    var ok = false;
    defer if (!ok) fsx.deleteFile(tmp_path) catch {};
    {
        const f = try fsx.createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(content);
    }
    try fsx.rename(tmp_path, path);
    ok = true;
}

// ── Phase 3: in-session re-exec ──

pub const min_idle_ms_default: u64 = update_config.min_idle_ms_override orelse 60_000;
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
    // Don't even attempt an apply we know will fail: a root-owned
    // install used to retry every 60s of idle for the whole session,
    // flashing "auto-update failed: NotWritable" each time, which the
    // seeded ~/.issyrc and the docs both promised was a silent no-op.
    if (!selfIsWritable()) return false;
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

    var argv0_buf: [fsx.max_path_bytes]u8 = undefined;
    const argv0 = fsx.selfExePath(&argv0_buf) catch return ApplyError.SelfExePathFailed;

    // Writability check — the binary swap uses rename(2), which needs the
    // parent directory to be writable. faccessat with W_OK on the file
    // itself is a reasonable proxy on Linux/macOS; fails for root-owned
    // installs like /usr/bin/issy.
    fsx.accessWritable(argv0) catch return ApplyError.NotWritable;

    const staged_path = std.fmt.allocPrint(allocator, "{s}/issy.staged", .{cache_dir}) catch return ApplyError.OutOfMemory;
    defer allocator.free(staged_path);
    const prev_path = std.fmt.allocPrint(allocator, "{s}/issy.prev", .{cache_dir}) catch return ApplyError.OutOfMemory;
    defer allocator.free(prev_path);

    // Confirm staged binary still exists and looks sane.
    const staged_stat = fsx.statFile(staged_path) catch return ApplyError.NoStagedBinary;
    if (staged_stat.kind != .file) return ApplyError.NoStagedBinary;
    if (staged_stat.size < 1024) return ApplyError.NoStagedBinary;

    // Re-verify the staged binary against the cached signed manifest at
    // the moment of use, not just at stage time — the file may have sat
    // in the user-writable cache for days. A failure deletes the staged
    // binary so a fresh worker run can re-download it.
    verifyStagedBinary(allocator, cache_dir, staged_path) catch {
        fsx.deleteFile(staged_path) catch {};
        return ApplyError.NoStagedBinary;
    };

    // Write resume file before touching the binary, so if anything goes
    // wrong we haven't broken the running instance. The name carries the
    // pid so two instances applying in the same second don't collide on
    // one path (and clobber/double-delete each other's record).
    const now_ns = fsx.nowNanos();
    const resume_path = std.fmt.allocPrint(allocator, "{s}/resume.{d}.{d}.txt", .{ cache_dir, std.c.getpid(), @as(i64, @intCast(@divTrunc(now_ns, std.time.ns_per_s))) }) catch return ApplyError.OutOfMemory;
    defer allocator.free(resume_path);

    writeResumeFile(resume_path, ed, now_ns) catch return ApplyError.ResumeWriteFailed;

    // Snapshot the currently-running binary so --rollback has something to
    // restore, plus its checksum so rollback can refuse a tampered
    // snapshot. Best-effort: a failure here doesn't block the apply.
    copyFileBestEffort(argv0, prev_path);
    writePrevChecksum(allocator, cache_dir, argv0);

    // Atomic binary swap. From this point the next execve call is the only
    // reasonable way forward — the current in-memory image is out of sync
    // with the file that argv0 now points to.
    fsx.rename(staged_path, argv0) catch {
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

    // fsx.execv replaces the current process image on success.
    fsx.execv(allocator, argv) catch {
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
    var tmp_path_buf: [fsx.max_path_bytes + 48]u8 = undefined;
    const tmp_path = try uniqueTmpPath(&tmp_path_buf, path);

    const f = try fsx.createFile(tmp_path, .{ .truncate = true });
    defer f.close();

    var buf: [4096]u8 = undefined;
    const content = try std.fmt.bufPrint(&buf, "v{d}\n{d}\n{d}\n{d}\n{d}\n{s}\n", .{
        resume_file_version,
        now_ns,
        ed.file_mtime orelse 0,
        ed.cursor.line,
        ed.cursor.col,
        ed.getFilename(),
    });
    try f.writeAll(content);

    try fsx.rename(tmp_path, path);
}

fn copyFileBestEffort(src: []const u8, dst: []const u8) void {
    fsx.copyFile(src, dst) catch {};
}

/// Verify the staged binary's SHA-256 against the cached signed
/// manifest. Any failure (missing manifest, bad signature, hash
/// mismatch) rejects the staged binary.
/// May a staged binary described by this SIGNED manifest replace the
/// running one?
///
/// Requires the manifest to name its release and to be strictly newer
/// than the binary executing right now. Signature-and-hash alone is not
/// enough: an authentic manifest for an OLDER release describes an
/// authentic older binary, and installing it is a silent downgrade.
/// That needs no attacker — stage release N+1, upgrade by hand to N+2,
/// and the next idle would reinstall N+1 over it.
///
/// Fails CLOSED when our own epoch is unknown, the opposite of
/// shouldNotify's fail-open. A refused apply costs the user nothing
/// (they are still notified, and brew/install.sh still work), while an
/// unordered apply is exactly the bug. Unlike the notify path this
/// epoch comes from inside the signed manifest, so it cannot be forged
/// without the signing key.
fn applyOrderingOk(our_epoch: u64, manifest_commit: ?[]const u8, manifest_epoch: ?u64) bool {
    const mc = manifest_commit orelse return false;
    if (mc.len < 40) return false;
    // Never reinstall the exact binary we are already running.
    if (std.mem.eql(u8, mc[0..40], build_info.commit_sha[0..40])) return false;
    if (our_epoch == 0) return false;
    const me = manifest_epoch orelse return false;
    return me > our_epoch;
}

fn verifyStagedBinary(
    allocator: std.mem.Allocator,
    cache_dir: []const u8,
    staged_path: []const u8,
) !void {
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/sha256sums.txt", .{cache_dir});
    defer allocator.free(manifest_path);
    const sig_path = try std.fmt.allocPrint(allocator, "{s}/sha256sums.txt.sig", .{cache_dir});
    defer allocator.free(sig_path);

    const manifest = try fsx.readFileAlloc(allocator, manifest_path, max_manifest_size);
    defer allocator.free(manifest);
    const sig_bytes = try fsx.readFileAlloc(allocator, sig_path, max_sig_size);
    defer allocator.free(sig_bytes);

    try verifyManifestSignature(manifest, sig_bytes);

    // Bind the staged binary to a release that is actually newer than
    // ours. Until this check existed, apply() re-verified only the
    // signature and hash against the CACHED manifest, which an older
    // authentic release satisfies perfectly.
    if (!applyOrderingOk(
        build_info.commit_epoch,
        manifestHeaderField(manifest, commit_header),
        manifestEpoch(manifest),
    )) return error.StagedNotNewer;

    const asset_name = currentAssetName() orelse return error.NoAssetForPlatform;
    const expected_hex = findAssetHash(manifest, asset_name) orelse return error.AssetNotInManifest;
    var expected_hash: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected_hash, expected_hex) catch return error.BadHexHash;

    const staged = try fsx.readFileAlloc(allocator, staged_path, max_binary_size);
    defer allocator.free(staged);
    var actual_hash: [32]u8 = undefined;
    Sha256.hash(staged, &actual_hash, .{});
    if (!std.mem.eql(u8, &actual_hash, &expected_hash)) return error.HashMismatch;
}

/// Record the SHA-256 of the binary snapshotted to issy.prev so
/// --rollback can validate it later. Best-effort.
fn writePrevChecksum(allocator: std.mem.Allocator, cache_dir: []const u8, src: []const u8) void {
    const sha_path = std.fmt.allocPrint(allocator, "{s}/issy.prev.sha256", .{cache_dir}) catch return;
    defer allocator.free(sha_path);

    const data = fsx.readFileAlloc(allocator, src, max_binary_size) catch return;
    defer allocator.free(data);

    var hash: [32]u8 = undefined;
    Sha256.hash(data, &hash, .{});
    var hex_buf: [64]u8 = undefined;
    const hex = std.fmt.bufPrint(&hex_buf, "{x}", .{&hash}) catch return;
    writeAtomic(sha_path, hex) catch {};
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
/// True only if `path` is inside `$HOME/.cache/issy` and its basename
/// looks like a resume record (`resume.*.txt`). Guards `tryResume`
/// against deleting or reading an arbitrary user-supplied path.
fn isResumePathSafe(path: []const u8) bool {
    const home = fsx.getenv("HOME") orelse return false;
    var prefix_buf: [fsx.max_path_bytes]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buf, "{s}/.cache/issy/", .{home}) catch return false;
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const base = path[prefix.len..];
    // No further path separators — must be a direct child of the dir.
    if (std.mem.indexOfScalar(u8, base, '/') != null) return false;
    return std.mem.startsWith(u8, base, "resume.") and std.mem.endsWith(u8, base, ".txt");
}

pub fn tryResume(
    ed: *editor_mod.Editor,
    resume_path: []const u8,
) void {
    // `--resume` is an internal re-exec flag, but nothing stops a user
    // from passing an arbitrary path. Refuse to touch anything outside
    // the cache dir so `issy --resume ~/notes.txt file.c` can never
    // delete ~/notes.txt. Only a validated resume record is deleted
    // (below), never an unrelated or malformed file.
    if (!isResumePathSafe(resume_path)) return;

    const f = fsx.openFile(resume_path) catch return;
    defer f.close();

    var buf: [1024]u8 = undefined;
    const n = f.readAll(&buf) catch return;
    const content = buf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    const version_line = lines.next() orelse return;
    if (version_line.len < 2 or version_line[0] != 'v') return;
    const version = std.fmt.parseInt(u32, version_line[1..], 10) catch return;
    if (version != resume_file_version) return;

    // From here the file is a recognizable resume record (correct
    // version header), so removing it on the way out is safe.
    defer fsx.deleteFile(resume_path) catch {};

    const created_str = lines.next() orelse return;
    const created_ns = std.fmt.parseInt(i128, std.mem.trim(u8, created_str, " \r\t"), 10) catch return;

    const now_ns = fsx.nowNanos();
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
    const line_len = if (ed.buf.getLine(ed.cursor.line)) |info| info.len else 0;
    ed.cursor.col = @min(saved_col, line_len);
    ed.cursor.col_want = ed.cursor.col;
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
    const cache_dir = try ensureCacheDir(allocator);
    defer allocator.free(cache_dir);

    const prev_path = try std.fmt.allocPrint(allocator, "{s}/issy.prev", .{cache_dir});
    defer allocator.free(prev_path);

    var argv0_buf: [fsx.max_path_bytes]u8 = undefined;
    const argv0 = try fsx.selfExePath(&argv0_buf);

    fsx.accessWritable(argv0) catch return error.NotWritable;
    _ = fsx.statFile(prev_path) catch return error.NoPreviousBinary;

    // If apply() recorded a checksum for the snapshot, require it to
    // still match — a tampered issy.prev must not be swapped in. A
    // missing checksum file (pre-checksum snapshots) skips the check.
    const sha_path = try std.fmt.allocPrint(allocator, "{s}/issy.prev.sha256", .{cache_dir});
    defer allocator.free(sha_path);
    if (fsx.readFileAlloc(allocator, sha_path, 128)) |expected_hex_raw| {
        defer allocator.free(expected_hex_raw);
        const expected_hex = std.mem.trim(u8, expected_hex_raw, " \t\r\n");
        var expected_hash: [32]u8 = undefined;
        if (std.fmt.hexToBytes(&expected_hash, expected_hex)) |_| {
            const data = try fsx.readFileAlloc(allocator, prev_path, max_binary_size);
            defer allocator.free(data);
            var actual: [32]u8 = undefined;
            Sha256.hash(data, &actual, .{});
            if (!std.mem.eql(u8, &actual, &expected_hash)) return error.PreviousBinaryCorrupt;
        } else |_| {}
    } else |_| {}

    try fsx.rename(prev_path, argv0);
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
    // Either unknown (0, e.g. a no-git tarball build with no override)
    // or a plausible commit timestamp — never a garbage value that would
    // let a stale release look newer than us.
    try std.testing.expect(build_info.commit_epoch == 0 or build_info.commit_epoch > 1_500_000_000);
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
    const kp = if (comptime fsx.is_zig_016)
        Ed25519.KeyPair.generate(fsx.io())
    else
        Ed25519.KeyPair.generate();
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

    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
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

test "manifest header parsing" {
    const manifest =
        "# issy-commit: 0123456789abcdef0123456789abcdef01234567\n" ++
        "# issy-manifest-epoch: 1750000000\n" ++
        "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789  issy-linux-amd64\n";

    try std.testing.expectEqualStrings(
        "0123456789abcdef0123456789abcdef01234567",
        manifestHeaderField(manifest, commit_header).?,
    );
    try std.testing.expectEqual(@as(?u64, 1750000000), manifestEpoch(manifest));
    // Header lines must not confuse the asset-hash parser.
    try std.testing.expect(findAssetHash(manifest, "issy-linux-amd64") != null);
    // Manifests without headers parse as absent.
    try std.testing.expectEqual(@as(?u64, null), manifestEpoch("just  hashes\n"));
}

test "epoch anti-rollback decisions" {
    // First contact: anything goes.
    try std.testing.expect(epochAllows(null, null));
    try std.testing.expect(epochAllows(null, 100));
    // Once an epoch is cached, equal or newer is fine…
    try std.testing.expect(epochAllows(100, 100));
    try std.testing.expect(epochAllows(100, 101));
    // …older is a replay, and "no epoch at all" is what a replayed
    // pre-epoch release looks like.
    try std.testing.expect(!epochAllows(100, 99));
    try std.testing.expect(!epochAllows(100, null));
}

test "isResumePathSafe only accepts cache-dir resume records" {
    const home = fsx.getenv("HOME") orelse return error.SkipZigTest;
    var buf: [1024]u8 = undefined;

    const good = try std.fmt.bufPrint(&buf, "{s}/.cache/issy/resume.123.456.txt", .{home});
    try std.testing.expect(isResumePathSafe(good));

    // A user file outside the cache dir must be rejected (the bug this
    // guards: `issy --resume ~/notes.txt` must not delete notes.txt).
    var b2: [1024]u8 = undefined;
    const outside = try std.fmt.bufPrint(&b2, "{s}/notes.txt", .{home});
    try std.testing.expect(!isResumePathSafe(outside));

    // Right dir, wrong name.
    var b3: [1024]u8 = undefined;
    const wrong_name = try std.fmt.bufPrint(&b3, "{s}/.cache/issy/positions.txt", .{home});
    try std.testing.expect(!isResumePathSafe(wrong_name));

    // Path traversal out of the cache dir is rejected (no nested slash).
    var b4: [1024]u8 = undefined;
    const traversal = try std.fmt.bufPrint(&b4, "{s}/.cache/issy/sub/resume.1.2.txt", .{home});
    try std.testing.expect(!isResumePathSafe(traversal));
}

test "downloadAndStage rejects a manifest missing the commit/epoch headers" {
    // manifestHeaderField/manifestEpoch return null when absent, which the
    // mandatory-header logic turns into an error. Verify the primitives.
    const no_headers = "abc  issy-linux-amd64\n";
    try std.testing.expectEqual(@as(?[]const u8, null), manifestHeaderField(no_headers, commit_header));
    try std.testing.expectEqual(@as(?u64, null), manifestEpoch(no_headers));
}

test "parseCachedRelease handles both cache formats" {
    // Two-field format written by current CI.
    const two = parseCachedRelease("2222222222222222222222222222222222222222 1700000000\n").?;
    try std.testing.expectEqualStrings("2222222222222222222222222222222222222222", &two.sha);
    try std.testing.expectEqual(@as(u64, 1700000000), two.epoch);

    // Legacy single-field cache (written by any pre-1.4.1 worker).
    const one = parseCachedRelease("3333333333333333333333333333333333333333").?;
    try std.testing.expectEqual(@as(u64, 0), one.epoch);

    // Garbage epoch degrades to unknown rather than failing the parse.
    const bad = parseCachedRelease("4444444444444444444444444444444444444444 notanumber").?;
    try std.testing.expectEqual(@as(u64, 0), bad.epoch);

    try std.testing.expect(parseCachedRelease("short") == null);
    try std.testing.expect(parseCachedRelease("") == null);
}

test "shouldNotify requires the release to be strictly newer" {
    const ours = "1111111111111111111111111111111111111111";
    const other = "2222222222222222222222222222222222222222";

    // Same release: never notify, whatever the epochs say.
    try std.testing.expect(!shouldNotify(ours, 100, ours, 999));

    // THE REGRESSION: a cached OLDER release must not be advertised.
    // This is the state every user lands in right after upgrading via
    // brew or install.sh, since the installer never refreshes the cache.
    try std.testing.expect(!shouldNotify(ours, 200, other, 100));

    // Genuinely newer: notify.
    try std.testing.expect(shouldNotify(ours, 100, other, 200));

    // Equal epochs, different sha: not newer, so no notice.
    try std.testing.expect(!shouldNotify(ours, 100, other, 100));

    // Unknown epochs fail open (inequality), so a tarball build still
    // learns about updates.
    try std.testing.expect(shouldNotify(ours, 0, other, 200));
    try std.testing.expect(shouldNotify(ours, 100, other, 0));
    try std.testing.expect(shouldNotify(ours, 0, other, 0));
}

test "shouldStage: a non-writable install downloads nothing" {
    // The documented contract for root-owned installs (install.sh's
    // seeded ~/.issyrc, CONFIGURATION.md, issy.1) is a silent no-op.
    // Before this gate the worker re-fetched the whole binary — up to
    // 32 MiB — on every single launch, forever.
    try std.testing.expect(!shouldStage(true, true, true, false, true, false));

    // Everything satisfied: stage.
    try std.testing.expect(shouldStage(true, true, true, true, true, false));

    // Each individual gate closes it.
    try std.testing.expect(!shouldStage(false, true, true, true, true, false)); // autoupdate off
    try std.testing.expect(!shouldStage(true, false, true, true, true, false)); // no pubkey
    try std.testing.expect(!shouldStage(true, true, false, true, true, false)); // no platform asset
    try std.testing.expect(!shouldStage(true, true, true, true, false, false)); // not newer

    // Already staged for this release: don't re-download.
    try std.testing.expect(!shouldStage(true, true, true, true, true, true));
}

test "canAutoApply refuses once demoted to error_state" {
    var cfg = config_mod.Config.init();
    cfg.autoupdate = true;
    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    var state = UpdateState{ .status = .error_state };
    // A failed apply demotes to error_state so the 60s retry loop stops
    // for the rest of the session.
    try std.testing.expect(!canAutoApply(&state, &ed, &cfg, 120_000, min_idle_ms_default));

    // .staged still gates on everything else (writability is checked
    // against the real test-runner binary, so assert only the negative
    // cases here).
    state.status = .staged;
    try std.testing.expect(!canAutoApply(&state, &ed, &cfg, 0, min_idle_ms_default)); // not idle yet
    ed.modified = true;
    try std.testing.expect(!canAutoApply(&state, &ed, &cfg, 120_000, min_idle_ms_default)); // dirty buffer
}

test "applyOrderingOk refuses anything not strictly newer" {
    const ours = build_info.commit_sha[0..];
    const other = "2222222222222222222222222222222222222222";

    // THE DOWNGRADE REPRO, which needs no attacker: release N+1 was
    // staged, the user then upgraded by hand to N+2, and the staged
    // older binary must not be installed over it.
    try std.testing.expect(!applyOrderingOk(2000, other, 1000));

    // Strictly newer: allowed.
    try std.testing.expect(applyOrderingOk(1000, other, 2000));

    // Same epoch is not newer.
    try std.testing.expect(!applyOrderingOk(1000, other, 1000));

    // Never reinstall the binary we're already running.
    try std.testing.expect(!applyOrderingOk(1000, ours, 9999));

    // Fails CLOSED on anything unknown — the opposite of shouldNotify.
    try std.testing.expect(!applyOrderingOk(0, other, 2000)); // our epoch unknown
    try std.testing.expect(!applyOrderingOk(1000, other, null)); // manifest epoch missing
    try std.testing.expect(!applyOrderingOk(1000, null, 2000)); // manifest commit missing
    try std.testing.expect(!applyOrderingOk(1000, "tooshort", 2000));
}
