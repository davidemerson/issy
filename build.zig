const std = @import("std");
const builtin = @import("builtin");

// Issy supports the Zig 0.15.x and 0.16.x series. 0.16 moved most of
// `std.fs` under `std.Io.Dir` (with a threaded `io` argument), which
// src/fsx.zig papers over; this file carries its own small comptime
// branches for the std.Build API differences. The gate runs at comptime
// so unsupported toolchains see this message instead of a cryptic
// stdlib error.
const zig_016 = builtin.zig_version.order(.{ .major = 0, .minor = 16, .patch = 0 }) != .lt;
comptime {
    const min_zig_version = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 0 };
    const max_zig_version = std.SemanticVersion{ .major = 0, .minor = 17, .patch = 0 };
    if (builtin.zig_version.order(min_zig_version) == .lt or
        builtin.zig_version.order(max_zig_version) != .lt)
    {
        @compileError("issy requires Zig 0.15.x or 0.16.x (CI exercises 0.15.2 and 0.16.0).");
    }
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build-info overrides for builds without a usable `.git` — chiefly
    // the Homebrew stable build, which compiles the GitHub source
    // tarball (no repo, so git rev-parse fails). The formula passes the
    // release commit recorded at tag time via `-Dcommit`, plus
    // `-Drelease=true`, so `issy --version` and the update-notify check
    // work on brew installs instead of falling back to a "dev" stamp.
    const commit_opt = b.option([]const u8, "commit", "Override the commit SHA embedded in build_info (40 hex chars)");
    const release_opt = b.option(bool, "release", "Mark build_info as a release build") orelse false;
    const commit_epoch_opt = b.option([]const u8, "commit-epoch", "Override the commit timestamp embedded in build_info (unix seconds); pairs with -Dcommit for builds with no .git");

    // TEST-ONLY update seams. These exist so the integration suite can
    // point a throwaway binary at a loopback fixture server signed with
    // a throwaway key. A build with no -Dupdate-* flag rewrites
    // src/update_config.zig back to all-null on EVERY configure, so an
    // override can never survive into a release binary and an
    // accidentally-overridden tree self-heals on the next plain build.
    const update_base_url_opt = b.option([]const u8, "update-base-url", "TEST ONLY: base URL for update artifacts; must end in '/'");
    const update_pubkey_opt = b.option([]const u8, "update-pubkey", "TEST ONLY: Ed25519 manifest-verification public key, 64 hex chars");
    const update_min_idle_opt = b.option([]const u8, "update-min-idle-ms", "TEST ONLY: idle milliseconds before in-session auto-apply");

    // Generate src/build_info.zig with version + commit SHA + build type.
    // Runs at configure time so `@import("build_info.zig")` from main.zig works.
    writeBuildInfo(b, commit_opt, release_opt, commit_epoch_opt) catch |err| {
        std.debug.print("warning: failed to write build_info.zig ({s}); using dev fallback\n", .{@errorName(err)});
    };

    // Fatal on failure, unlike writeBuildInfo's warn-and-continue: if
    // this write fails while a stale override file is on disk, we would
    // ship a binary pointed at someone else's URL or key.
    writeUpdateConfig(b, update_base_url_opt, update_pubkey_opt, update_min_idle_opt) catch |err| {
        std.debug.print("error: failed to write src/update_config.zig ({s})\n", .{@errorName(err)});
        std.process.exit(1);
    };

    const exe = b.addExecutable(.{
        .name = "issy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link libc on every POSIX target where it's required or idiomatic.
    // Modern OpenBSD kills processes that issue raw syscalls outside of
    // libc, so native OpenBSD builds must link libc — the cross-compile
    // from Linux/macOS to OpenBSD has never worked anyway (Zig doesn't
    // ship OpenBSD libc headers), and CI's openbsd target already has
    // "best-effort, tolerate failure" semantics in .github/workflows/ci.yml.
    const os_tag = target.result.os.tag;
    if (os_tag == .linux or os_tag == .macos or os_tag == .openbsd) {
        exe.root_module.link_libc = true;
    }

    b.installArtifact(exe);

    // Cross-compilation convenience targets.
    const cross_targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .openbsd },
    };

    const cross_step = b.step("cross", "Build for all cross-compilation targets");
    for (cross_targets) |ct| {
        const resolved = b.resolveTargetQuery(ct);
        const cross_exe = b.addExecutable(.{
            .name = "issy",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = resolved,
                .optimize = optimize,
            }),
        });
        const cross_os = ct.os_tag orelse .linux;
        if (cross_os == .linux or cross_os == .macos) {
            cross_exe.root_module.link_libc = true;
        }
        const cross_install = b.addInstallArtifact(cross_exe, .{});
        cross_step.dependOn(&cross_install.step);
    }

    // Keygen step — builds and runs tools/keygen.zig. Used once per repo
    // to bootstrap the auto-update signing key. Prints a PEM private key
    // and a Zig public-key array literal to stdout; the private key is
    // never persisted to disk by the tool.
    const keygen_mod = b.createModule(.{
        .root_source_file = b.path("tools/keygen.zig"),
        .target = target,
        .optimize = optimize,
    });
    // keygen goes through the same 0.15/0.16 shim as src/, so it needs
    // fsx as a named import (a relative ../src path would sit outside
    // the module root).
    const keygen_fsx = b.createModule(.{
        .root_source_file = b.path("src/fsx.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (os_tag == .linux or os_tag == .macos or os_tag == .openbsd) {
        keygen_mod.link_libc = true;
        keygen_fsx.link_libc = true;
    }
    keygen_mod.addImport("fsx", keygen_fsx);
    const keygen_exe = b.addExecutable(.{
        .name = "issy-keygen",
        .root_module = keygen_mod,
    });
    const run_keygen = b.addRunArtifact(keygen_exe);
    const keygen_step = b.step("keygen", "Generate Ed25519 signing keypair for auto-update");
    keygen_step.dependOn(&run_keygen.step);

    // Test step — run all tests across all source files.
    const source_files: []const []const u8 = &.{
        "src/unicode.zig",
        "src/fsx.zig",
        "src/buffer.zig",
        "src/term.zig",
        "src/config.zig",
        "src/syntax.zig",
        "src/render.zig",
        "src/editor.zig",
        "src/font.zig",
        "src/print.zig",
        "src/update.zig",
        "src/update_key.zig",
        "src/positions.zig",
        "src/main.zig",
    };

    const test_step = b.step("test", "Run all tests");
    for (source_files) |src| {
        const test_mod = b.createModule(.{
            .root_source_file = b.path(src),
            .target = target,
            .optimize = optimize,
        });
        // Link libc in tests too, matching the shipped binary — some code
        // (e.g. positions.zig's atomic temp-name via std.c.getpid) needs
        // libc, and a test exercising it would otherwise fail to link on
        // Linux/OpenBSD where libc isn't linked by default.
        if (os_tag == .linux or os_tag == .macos or os_tag == .openbsd) {
            test_mod.link_libc = true;
        }
        const unit_tests = b.addTest(.{ .root_module = test_mod });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
    // Compile keygen under `zig build test` so a toolchain change can't
    // break it unnoticed (it lives outside source_files because it has
    // no tests of its own). COMPILE ONLY — never addRunArtifact here:
    // keygen prints a PKCS#8 private key to stdout, which in CI would
    // land in a public Actions log.
    test_step.dependOn(&keygen_exe.step);
}

// Writes src/update_config.zig — the TEST-ONLY seams that let the
// integration suite drive the update path against a local fixture
// server without touching the network or the release signing key.
//
// Safety properties, which are the whole reason this is a generated
// file rather than a runtime env var or config key:
//   * A plain `zig build` (no -Dupdate-* flags) rewrites this file with
//     all-null values on EVERY configure, so a tree that was once built
//     with overrides heals itself and there is no persistent state to
//     forget to reset.
//   * With the values null, `orelse` folds at comptime: a release binary
//     contains no override branch, string, or symbol at all.
//   * A malformed value is a hard build failure, never a silent
//     fall-back to the release defaults — so a binary that "looks"
//     release-keyed but isn't cannot exist.
//   * Any override build prints a warning and stamps `test-update` into
//     `issy --version`, which the CLI test asserts is absent from a
//     normally-built binary.
fn writeUpdateConfig(b: *std.Build, url: ?[]const u8, pubkey_hex: ?[]const u8, min_idle: ?[]const u8) !void {
    const allocator = b.allocator;

    if (url) |u| {
        if (!std.mem.startsWith(u8, u, "http://") and !std.mem.startsWith(u8, u, "https://")) {
            std.debug.print("error: -Dupdate-base-url must start with http:// or https://\n", .{});
            std.process.exit(1);
        }
        // The asset URL is built as base_url ++ asset_name.
        if (!std.mem.endsWith(u8, u, "/")) {
            std.debug.print("error: -Dupdate-base-url must end with '/'\n", .{});
            std.process.exit(1);
        }
    }
    if (pubkey_hex) |h| {
        if (h.len != 64 or !isHexN(h)) {
            std.debug.print("error: -Dupdate-pubkey must be exactly 64 hex characters\n", .{});
            std.process.exit(1);
        }
    }
    if (min_idle) |m| {
        if (m.len == 0 or !isDecimal(m)) {
            std.debug.print("error: -Dupdate-min-idle-ms must be decimal\n", .{});
            std.process.exit(1);
        }
    }

    var url_buf: [512]u8 = undefined;
    const url_line = if (url) |u|
        try std.fmt.bufPrint(&url_buf, "\"{s}\"", .{u})
    else
        "null";

    var key_buf: [512]u8 = undefined;
    const key_line = if (pubkey_hex) |h| blk: {
        var raw: [32]u8 = undefined;
        _ = std.fmt.hexToBytes(&raw, h) catch {
            std.debug.print("error: -Dupdate-pubkey is not valid hex\n", .{});
            std.process.exit(1);
        };
        var w: usize = 0;
        var out: [512]u8 = undefined;
        w += (try std.fmt.bufPrint(out[w..], ".{{ ", .{})).len;
        for (raw) |byte| {
            w += (try std.fmt.bufPrint(out[w..], "0x{x:0>2}, ", .{byte})).len;
        }
        w += (try std.fmt.bufPrint(out[w..], "}}", .{})).len;
        @memcpy(key_buf[0..w], out[0..w]);
        break :blk key_buf[0..w];
    } else "null";

    const any = url != null or pubkey_hex != null or min_idle != null;

    const content = try std.fmt.allocPrint(allocator,
        \\// Generated by build.zig. Do not edit; do not commit.
        \\//
        \\// TEST-ONLY overrides for the auto-update path. A plain
        \\// `zig build` rewrites this file with all-null values, so a
        \\// release binary never contains an override.
        \\pub const base_url_override: ?[]const u8 = {s};
        \\pub const public_key_override: ?[32]u8 = {s};
        \\pub const min_idle_ms_override: ?u64 = {s};
        \\pub const any_override: bool = {s};
        \\
    , .{ url_line, key_line, min_idle orelse "null", if (any) "true" else "false" });
    defer allocator.free(content);

    if (any) {
        std.debug.print("warning: building with TEST update overrides — do not ship this binary\n", .{});
    }

    const path = "src/update_config.zig";
    const existing = if (zig_016)
        std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, allocator, .limited(4096)) catch null
    else
        std.fs.cwd().readFileAlloc(allocator, path, 4096) catch null;
    if (existing) |buf| {
        defer allocator.free(buf);
        if (std.mem.eql(u8, buf, content)) return;
    }

    if (zig_016) {
        const file = try std.Io.Dir.cwd().createFile(b.graph.io, path, .{});
        defer file.close(b.graph.io);
        try file.writeStreamingAll(b.graph.io, content);
    } else {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }
}

fn isHexN(s: []const u8) bool {
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

// Writes src/build_info.zig with version, commit SHA, build type, and
// the commit's timestamp.
// Precedence: an explicit `-Dcommit` override (used by the Homebrew
// stable build, which has no `.git`) wins; otherwise a clean git tree
// embeds the full 40-char SHA and marks build_type = .release; anything
// else falls back to "dev".
//
// commit_epoch is what lets the update path tell *newer* from merely
// *different*: without it, a cached release SHA that simply differs from
// ours reads as "update available" even when it is older, and a staged
// binary can be applied over a newer manual install. 0 means unknown,
// in which case the update path falls back to inequality for notifying
// and refuses to auto-apply at all.
fn writeBuildInfo(b: *std.Build, commit_override: ?[]const u8, release_override: bool, epoch_override: ?[]const u8) !void {
    const allocator = b.allocator;

    var version_buf: [32]u8 = undefined;
    const version = readVersionFromZon(b, &version_buf) catch "0.0.0";

    const commit_sha: [40]u8, const is_release: bool = blk: {
        // 1. Explicit override (validated as 40 hex chars).
        if (commit_override) |c| {
            if (isHex40(c)) {
                var sha: [40]u8 = undefined;
                @memcpy(&sha, c[0..40]);
                break :blk .{ sha, release_override };
            }
            // A malformed override falls through to git/dev rather than
            // silently embedding garbage.
        }

        // 2. Try git rev-parse HEAD, then check whether the tree is clean.
        const git_head = runGitCommand(b, allocator, &.{ "git", "rev-parse", "HEAD" }) catch {
            break :blk .{ dev_sha_padded(), false };
        };
        defer allocator.free(git_head);

        if (git_head.len < 40) break :blk .{ dev_sha_padded(), false };
        var sha: [40]u8 = undefined;
        @memcpy(&sha, git_head[0..40]);

        // `git status --porcelain` returns empty on a clean tree.
        const status = runGitCommand(b, allocator, &.{ "git", "status", "--porcelain" }) catch {
            break :blk .{ sha, false };
        };
        defer allocator.free(status);
        const dirty = std.mem.trim(u8, status, " \t\r\n").len != 0;
        // Only a clean tree earns a release stamp on the git path.
        // `-Drelease=true` is honored solely alongside a valid `-Dcommit`
        // (handled above) — it must not be able to mint a "release" over
        // uncommitted local changes.
        break :blk .{ sha, !dirty };
    };

    const commit_epoch: u64 = blk: {
        // 1. Explicit override (validated as decimal digits), for builds
        //    with no .git — the Homebrew stable path passes it beside
        //    -Dcommit.
        if (epoch_override) |e| {
            if (e.len > 0 and isDecimal(e)) {
                if (std.fmt.parseInt(u64, e, 10)) |v| break :blk v else |_| {}
            }
            // Malformed falls through to git/unknown rather than
            // embedding garbage, matching -Dcommit's behavior.
        }
        // 2. The commit's own timestamp. Works in the --depth 1 clone
        //    install.sh makes, since %ct reads the commit object itself.
        const out = runGitCommand(b, allocator, &.{ "git", "show", "-s", "--format=%ct", "HEAD" }) catch break :blk 0;
        defer allocator.free(out);
        const trimmed = std.mem.trim(u8, out, " \t\r\n");
        break :blk std.fmt.parseInt(u64, trimmed, 10) catch 0;
    };

    const content = try std.fmt.allocPrint(allocator,
        \\// Generated by build.zig. Do not edit; do not commit.
        \\pub const version = "{s}";
        \\pub const commit_sha = "{s}";
        \\pub const BuildType = enum {{ release, dev }};
        \\pub const build_type: BuildType = .{s};
        \\/// Unix seconds of the commit this was built from; 0 = unknown.
        \\/// The update path uses this to require a release be strictly
        \\/// newer before notifying about it or applying it.
        \\pub const commit_epoch: u64 = {d};
        \\
    , .{ version, &commit_sha, if (is_release) "release" else "dev", commit_epoch });
    defer allocator.free(content);

    // Write to src/build_info.zig. Only rewrite if content changed to keep caches happy.
    const path = "src/build_info.zig";
    const existing = if (zig_016)
        std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, allocator, .limited(4096)) catch null
    else
        std.fs.cwd().readFileAlloc(allocator, path, 4096) catch null;
    if (existing) |buf| {
        defer allocator.free(buf);
        if (std.mem.eql(u8, buf, content)) return;
    }

    if (zig_016) {
        const file = try std.Io.Dir.cwd().createFile(b.graph.io, path, .{});
        defer file.close(b.graph.io);
        try file.writeStreamingAll(b.graph.io, content);
    } else {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();
        try file.writeAll(content);
    }
}

fn readVersionFromZon(b: *std.Build, out: []u8) ![]const u8 {
    const zon = if (zig_016)
        try std.Io.Dir.cwd().readFileAlloc(b.graph.io, "build.zig.zon", std.heap.page_allocator, .limited(4096))
    else
        try std.fs.cwd().readFileAlloc(std.heap.page_allocator, "build.zig.zon", 4096);
    defer std.heap.page_allocator.free(zon);
    const needle = ".version = \"";
    const start = std.mem.indexOf(u8, zon, needle) orelse return error.NotFound;
    const vstart = start + needle.len;
    const vend = std.mem.indexOfScalarPos(u8, zon, vstart, '"') orelse return error.NotFound;
    const v = zon[vstart..vend];
    if (v.len > out.len) return error.TooLong;
    @memcpy(out[0..v.len], v);
    return out[0..v.len];
}

fn runGitCommand(b: *std.Build, allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    if (zig_016) {
        const result = try std.process.run(allocator, b.graph.io, .{
            .argv = argv,
            .stdout_limit = .limited(4096),
            .stderr_limit = .limited(4096),
        });
        allocator.free(result.stderr);
        errdefer allocator.free(result.stdout);
        switch (result.term) {
            .exited => |code| if (code != 0) return error.GitFailed,
            else => return error.GitFailed,
        }
        return result.stdout;
    }
    var child = std.process.Child.init(argv, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(allocator, 4096);
    errdefer allocator.free(out);
    const term = try child.wait();
    switch (term) {
        .Exited => |code| if (code != 0) {
            allocator.free(out);
            return error.GitFailed;
        },
        else => {
            allocator.free(out);
            return error.GitFailed;
        },
    }
    return out;
}

fn isDecimal(s: []const u8) bool {
    for (s) |c| {
        if (c < '0' or c > '9') return false;
    }
    return true;
}

fn isHex40(s: []const u8) bool {
    if (s.len != 40) return false;
    for (s) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!ok) return false;
    }
    return true;
}

fn dev_sha_padded() [40]u8 {
    var sha: [40]u8 = undefined;
    @memset(&sha, '0');
    const tag = "dev";
    @memcpy(sha[0..tag.len], tag);
    return sha;
}
