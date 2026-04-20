//! issy — a text editor that looks like a printed page.
//!
//! Entry point: parses command-line arguments, initializes configuration
//! and terminal, loads the requested file, runs the main editing loop,
//! and cleans up on exit.

const std = @import("std");
const builtin = @import("builtin");
const config_mod = @import("config.zig");
const term = @import("term.zig");
const editor_mod = @import("editor.zig");
const render_mod = @import("render.zig");
const print_mod = @import("print.zig");
const update_mod = @import("update.zig");
const build_info = @import("build_info.zig");

comptime {
    if (builtin.os.tag == .windows) {
        @compileError("issy does not support Windows. Target Linux, macOS, or OpenBSD.");
    }
}

const Args = struct {
    file: ?[]const u8 = null,
    config_path: ?[]const u8 = null,
    theme: ?[]const u8 = null,
    font: ?[]const u8 = null,
    print_output: ?[]const u8 = null,
    resume_path: ?[]const u8 = null,
    no_config: bool = false,
    show_version: bool = false,
    show_help: bool = false,
    rollback: bool = false,
};

/// Apply --theme/--font overrides on top of a freshly-loaded Config.
/// Broken out so config auto-reload can reapply them after re-reading
/// ~/.issyrc; otherwise a reload would silently drop CLI overrides.
fn applyCliOverrides(cfg: *config_mod.Config, args: Args) void {
    if (args.theme) |t| {
        if (std.mem.eql(u8, t, "paper")) {
            cfg.theme = config_mod.paper_theme;
        }
    }
    if (args.font) |f| {
        if (f.len <= 512) {
            @memcpy(cfg.font_file[0..f.len], f);
            cfg.font_file_len = f.len;
        }
    }
}

fn parseArgs() Args {
    var args_result = Args{};
    var args_iter = std.process.args();
    _ = args_iter.skip(); // skip program name

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v")) {
            args_result.show_version = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            args_result.show_help = true;
        } else if (std.mem.eql(u8, arg, "--no-config")) {
            args_result.no_config = true;
        } else if (std.mem.eql(u8, arg, "--config")) {
            args_result.config_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--theme")) {
            args_result.theme = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--font")) {
            args_result.font = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--print")) {
            args_result.print_output = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--resume")) {
            args_result.resume_path = args_iter.next();
        } else if (std.mem.eql(u8, arg, "--rollback")) {
            args_result.rollback = true;
        } else if (arg[0] != '-') {
            args_result.file = arg;
        }
    }

    return args_result;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = parseArgs();

    if (args.rollback) {
        const stdout = std.fs.File.stdout();
        update_mod.rollback(allocator) catch |e| {
            const stderr = std.fs.File.stderr();
            var msg_buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&msg_buf, "issy --rollback failed: {s}\n", .{@errorName(e)}) catch "issy --rollback failed\n";
            stderr.writeAll(msg) catch {};
            std.process.exit(1);
        };
        try stdout.writeAll("issy: rolled back to previous version\n");
        return;
    }

    if (args.show_version) {
        const stdout = std.fs.File.stdout();
        var buf: [128]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "issy {s} ({s} {s})\n", .{
            build_info.version,
            build_info.commit_sha[0..@min(7, build_info.commit_sha.len)],
            @tagName(build_info.build_type),
        }) catch "issy\n";
        try stdout.writeAll(line);
        return;
    }

    if (args.show_help) {
        const stdout = std.fs.File.stdout();
        try stdout.writeAll(
            \\issy — a minimal text editor
            \\
            \\Usage: issy [options] [file[:line]]
            \\
            \\Options:
            \\  --version    Print version and exit
            \\  --help       Print this help and exit
            \\  --config F   Use config file F
            \\  --theme T    Override theme (default, paper)
            \\  --font F     TTF/OTF font for PDF output
            \\  --no-config  Skip loading config file
            \\  --print F    Export to PDF and exit
            \\  --rollback   Swap in the previous binary (if any) and exit
            \\
            \\Keybindings:
            \\  Ctrl+S save  Ctrl+Q quit  Ctrl+F search  Ctrl+H replace
            \\  Ctrl+G next  Ctrl+Z undo  Ctrl+Y redo    Ctrl+D multi-cursor
            \\  Ctrl+C copy  Ctrl+X cut   Ctrl+V paste   Ctrl+A select all
            \\  Ctrl+O open  Ctrl+N new   Ctrl+P print   Ctrl+R reload
            \\
        );
        return;
    }

    // Resolve the config path (--config wins, otherwise default ~/.issyrc).
    // We hold on to the path + mtime so the main loop can auto-reload
    // when the user edits the config file in another window (or in issy
    // itself).
    var cfg_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cfg_path_len: usize = 0;
    var cfg_mtime: i128 = 0;

    if (!args.no_config) {
        if (args.config_path) |p| {
            if (p.len <= cfg_path_buf.len) {
                @memcpy(cfg_path_buf[0..p.len], p);
                cfg_path_len = p.len;
            }
        } else if (config_mod.resolveDefaultPath(cfg_path_buf[0..])) |p| {
            cfg_path_len = p.len;
        }
    }

    var cfg = config_mod.Config.init();
    if (cfg_path_len > 0) {
        cfg = config_mod.load(allocator, cfg_path_buf[0..cfg_path_len]);
        if (config_mod.statMtime(cfg_path_buf[0..cfg_path_len])) |m| cfg_mtime = m;
    }
    applyCliOverrides(&cfg, args);

    // Init editor
    var ed = editor_mod.Editor.init(&cfg, allocator);
    defer ed.deinit();

    // Load file if specified
    if (args.file) |f| {
        ed.openFile(f) catch |e| {
            ed.setStatusMessage(@errorName(e));
        };
    }

    // If we were re-exec'd by the auto-update path, restore the cursor
    // position from the resume file. Safe no-op if the file is stale,
    // missing, or mtime doesn't match.
    if (args.resume_path) |rp| {
        update_mod.tryResume(&ed, rp);
    }

    // Print mode: generate PDF and exit
    if (args.print_output) |output| {
        print_mod.toPdf(&ed, output) catch |e| {
            const stderr = std.fs.File.stderr();
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Error generating PDF: {s}\n", .{@errorName(e)}) catch "Error\n";
            stderr.writeAll(msg) catch {};
            std.process.exit(1);
        };
        return;
    }

    // Init terminal — requires a real tty
    if (!std.posix.isatty(std.fs.File.stdin().handle)) {
        const stderr = std.fs.File.stderr();
        stderr.writeAll("issy: stdin is not a terminal\n") catch {};
        std.process.exit(1);
    }
    try term.init();
    defer term.deinit();

    // Init renderer
    const size = term.getSize();
    var renderer = try render_mod.Renderer.init(allocator, size.rows, size.cols);
    defer renderer.deinit();

    ed.visible_rows = size.rows;
    ed.visible_cols = size.cols;

    // Auto-update check. Reads cached ~/.cache/issy/commit.txt (if any) to set
    // the initial status, then forks a detached worker to refresh the cache
    // for next run. Never blocks on the network.
    var update_state = update_mod.UpdateState{};
    update_mod.startupCheck(&update_state, allocator, &cfg);
    if (update_state.status == .available and cfg.notify_updates) {
        ed.setStatusMessage(update_state.getMessage());
    }

    // Main loop
    var last_stat_check: i64 = 0;
    var idle_ms: u64 = 0;
    while (true) {
        // Check for resize
        const new_size = term.getSize();
        if (new_size.rows != renderer.rows or new_size.cols != renderer.cols) {
            try renderer.resize(new_size.rows, new_size.cols);
            ed.visible_rows = new_size.rows;
            ed.visible_cols = new_size.cols;
        }

        // Render
        try renderer.drawFrame(&ed);

        // Read input
        const key = try term.readKey();
        if (key == .none) {
            // term.readKey has a ~100ms timeout; each .none return is
            // roughly one quiet tick. Use this to drive drag
            // autoscroll (the terminal only sends drag events when
            // the pointer moves, so a stationary drag at the
            // viewport edge would otherwise freeze) and for the idle
            // auto-update accumulator.
            if (ed.is_dragging) {
                _ = ed.dragAutoscrollTick();
                // Fall through so the top of the loop repaints.
                continue;
            }
            idle_ms += 100;
            if (update_mod.canAutoApply(&update_state, &ed, &cfg, idle_ms, update_mod.min_idle_ms_default)) {
                // apply either succeeds (noreturn, process is replaced) or
                // returns an error — in which case we keep running and
                // show the error in the status bar.
                update_mod.apply(allocator, &ed) catch |e| {
                    var buf: [128]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "auto-update failed: {s}", .{@errorName(e)}) catch "auto-update failed";
                    ed.setStatusMessage(msg);
                    // Back off: don't retry until more idle time accrues.
                    idle_ms = 0;
                };
            }
            continue;
        }

        // Real keystroke — reset idle counter.
        idle_ms = 0;

        // File change detection (throttled to 1/sec)
        const now = std.time.milliTimestamp();
        if (now - last_stat_check > 1000) {
            ed.checkFileChanged();
            // Config auto-reload: if ~/.issyrc (or --config path) has a
            // newer mtime than what we last loaded, reread it and
            // reapply CLI overrides. Failure is silent — the editor
            // keeps using the previous config rather than blanking it.
            if (cfg_path_len > 0) {
                if (config_mod.statMtime(cfg_path_buf[0..cfg_path_len])) |m| {
                    if (m != cfg_mtime) {
                        cfg = config_mod.load(allocator, cfg_path_buf[0..cfg_path_len]);
                        applyCliOverrides(&cfg, args);
                        cfg_mtime = m;
                        ed.setStatusMessage("Config reloaded.");
                    }
                }
            }
            last_stat_check = now;
        }

        // Handle key
        switch (ed.handleKey(key)) {
            .quit, .force_quit => break,
            .export_pdf => {
                // Editor guarantees filename + font_file are populated
                // before it returns this action. Write to
                // "<filename>.pdf" alongside the source; failures land
                // as a status-bar message rather than a crash.
                const filename = ed.getFilename();
                var out_buf: [std.fs.max_path_bytes]u8 = undefined;
                const out_path = std.fmt.bufPrint(&out_buf, "{s}.pdf", .{filename}) catch {
                    ed.setStatusMessage("PDF export: path too long");
                    continue;
                };
                print_mod.toPdf(&ed, out_path) catch |e| {
                    var msg_buf: [192]u8 = undefined;
                    const msg = std.fmt.bufPrint(&msg_buf, "PDF export failed: {s}", .{@errorName(e)}) catch "PDF export failed";
                    ed.setStatusMessage(msg);
                    continue;
                };
                var msg_buf: [std.fs.max_path_bytes + 32]u8 = undefined;
                const msg = std.fmt.bufPrint(&msg_buf, "Wrote {s}", .{out_path}) catch "Wrote PDF";
                ed.setStatusMessage(msg);
            },
            else => {},
        }
    }
}

test "main placeholder" {}

test {
    _ = @import("unicode.zig");
    _ = @import("buffer.zig");
    _ = @import("term.zig");
    _ = @import("config.zig");
    _ = @import("syntax.zig");
    _ = @import("render.zig");
    _ = @import("editor.zig");
    _ = @import("font.zig");
    _ = @import("print.zig");
}
