const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "issy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link libc on POSIX targets for termios.
    const os_tag = target.result.os.tag;
    if (os_tag == .linux or os_tag == .macos or os_tag == .openbsd or os_tag == .freebsd or os_tag == .netbsd) {
        exe.linkLibC();
    }

    b.installArtifact(exe);

    // Cross-compilation convenience targets.
    const cross_targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .gnu },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .windows, .abi = .gnu },
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
        if (cross_os == .linux or cross_os == .macos or cross_os == .openbsd or cross_os == .freebsd or cross_os == .netbsd) {
            cross_exe.linkLibC();
        }
        const cross_install = b.addInstallArtifact(cross_exe, .{});
        cross_step.dependOn(&cross_install.step);
    }

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
