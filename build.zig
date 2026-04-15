const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Generate src/build_info.zig with version + commit SHA + build type.
    // Runs at configure time so `@import("build_info.zig")` from main.zig works.
    writeBuildInfo(b) catch |err| {
        std.debug.print("warning: failed to write build_info.zig ({s}); using dev fallback\n", .{@errorName(err)});
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
        exe.linkLibC();
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
            cross_exe.linkLibC();
        }
        const cross_install = b.addInstallArtifact(cross_exe, .{});
        cross_step.dependOn(&cross_install.step);
    }

    // Keygen step — builds and runs tools/keygen.zig. Used once per repo
    // to bootstrap the auto-update signing key. Prints a PEM private key
    // and a Zig public-key array literal to stdout; the private key is
    // never persisted to disk by the tool.
    const keygen_exe = b.addExecutable(.{
        .name = "issy-keygen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/keygen.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_keygen = b.addRunArtifact(keygen_exe);
    const keygen_step = b.step("keygen", "Generate Ed25519 signing keypair for auto-update");
    keygen_step.dependOn(&run_keygen.step);

    // Test step — run all tests across all source files.
    const source_files: []const []const u8 = &.{
        "src/unicode.zig",
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
        "src/main.zig",
    };

    const test_step = b.step("test", "Run all tests");
    for (source_files) |src| {
        const unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(src),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        test_step.dependOn(&run_unit_tests.step);
    }
}

// Writes src/build_info.zig with version, commit SHA, and build type.
// On a clean release tree (CI or tagged builds), embeds the full 40-char SHA
// and marks build_type = .release. On anything else, falls back to "dev".
fn writeBuildInfo(b: *std.Build) !void {
    const allocator = b.allocator;

    var version_buf: [32]u8 = undefined;
    const version = readVersionFromZon(&version_buf) catch "0.0.0";

    // Try git rev-parse HEAD. On success, check if tree is clean.
    const commit_sha: [40]u8, const is_release: bool = git_block: {
        const git_head = runGitCommand(allocator, &.{ "git", "rev-parse", "HEAD" }) catch {
            break :git_block .{ dev_sha_padded(), false };
        };
        defer allocator.free(git_head);

        if (git_head.len < 40) break :git_block .{ dev_sha_padded(), false };
        var sha: [40]u8 = undefined;
        @memcpy(&sha, git_head[0..40]);

        // Check if tree is dirty. `git status --porcelain` returns empty on clean.
        const status = runGitCommand(allocator, &.{ "git", "status", "--porcelain" }) catch {
            break :git_block .{ sha, false };
        };
        defer allocator.free(status);
        const dirty = std.mem.trim(u8, status, " \t\r\n").len != 0;
        break :git_block .{ sha, !dirty };
    };

    const content = try std.fmt.allocPrint(allocator,
        \\// Generated by build.zig. Do not edit; do not commit.
        \\pub const version = "{s}";
        \\pub const commit_sha = "{s}";
        \\pub const BuildType = enum {{ release, dev }};
        \\pub const build_type: BuildType = .{s};
        \\
    , .{ version, &commit_sha, if (is_release) "release" else "dev" });
    defer allocator.free(content);

    // Write to src/build_info.zig. Only rewrite if content changed to keep caches happy.
    const path = "src/build_info.zig";
    const existing = std.fs.cwd().readFileAlloc(allocator, path, 4096) catch null;
    if (existing) |buf| {
        defer allocator.free(buf);
        if (std.mem.eql(u8, buf, content)) return;
    }

    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(content);
}

fn readVersionFromZon(out: []u8) ![]const u8 {
    const zon = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, "build.zig.zon", 4096);
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

fn runGitCommand(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
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

fn dev_sha_padded() [40]u8 {
    var sha: [40]u8 = undefined;
    @memset(&sha, '0');
    const tag = "dev";
    @memcpy(sha[0..tag.len], tag);
    return sha;
}
