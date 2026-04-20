//! Per-file cursor memory.
//!
//! Persists the most recent cursor (line, col) per file path to
//! ~/.cache/issy/positions.txt so reopening a file drops the caret
//! back where you left it. Best-effort — any I/O error silently
//! disables the feature for that call; the editor keeps working.
//!
//! Wire format: one entry per line,
//!   `<abs_path>\t<line>\t<col>\n`
//! Most-recently-updated entries live at the top; the file is capped
//! at `max_entries`. Parsing splits from the right on tabs so paths
//! that themselves contain tabs still decode correctly. Paths with
//! embedded newlines are rejected at record time (they'd break the
//! one-entry-per-line invariant).

const std = @import("std");

pub const Position = struct {
    line: usize,
    col: usize,
};

const max_entries: usize = 300;
/// Max bytes of positions.txt kept in memory at once. Enough for the
/// full 300-entry cap with generous path lengths; entries that don't
/// fit are dropped oldest-first.
const file_cap: usize = 48 * 1024;

/// Fill `buf` with the absolute path of the positions file
/// ($HOME/.cache/issy/positions.txt). Returns null if HOME is unset
/// or `buf` is too small.
fn resolveFilePath(buf: []u8) ?[]const u8 {
    const home = std.posix.getenv("HOME") orelse return null;
    const suffix = "/.cache/issy/positions.txt";
    const needed = home.len + suffix.len;
    if (needed > buf.len) return null;
    @memcpy(buf[0..home.len], home);
    @memcpy(buf[home.len..][0..suffix.len], suffix);
    return buf[0..needed];
}

const ParsedEntry = struct {
    path: []const u8,
    line: usize,
    col: usize,
};

fn parseEntry(text: []const u8) ?ParsedEntry {
    const last_tab = std.mem.lastIndexOfScalar(u8, text, '\t') orelse return null;
    if (last_tab == 0 or last_tab == text.len - 1) return null;
    const col_str = text[last_tab + 1 ..];
    const before_col = text[0..last_tab];

    const second_tab = std.mem.lastIndexOfScalar(u8, before_col, '\t') orelse return null;
    if (second_tab == 0 or second_tab == before_col.len - 1) return null;
    const line_str = before_col[second_tab + 1 ..];
    const path = before_col[0..second_tab];
    if (path.len == 0) return null;

    const line_num = std.fmt.parseInt(usize, line_str, 10) catch return null;
    const col_num = std.fmt.parseInt(usize, col_str, 10) catch return null;
    return .{ .path = path, .line = line_num, .col = col_num };
}

/// Look up the saved position for `abs_path`. Returns null on any I/O
/// error or when there's no matching entry. Caller is expected to have
/// resolved `abs_path` to a canonical absolute form already — the
/// comparison is a plain byte-wise equality.
pub fn lookup(abs_path: []const u8) ?Position {
    if (abs_path.len == 0) return null;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const positions_path = resolveFilePath(&path_buf) orelse return null;

    const file = std.fs.cwd().openFile(positions_path, .{}) catch return null;
    defer file.close();

    var content_buf: [file_cap]u8 = undefined;
    const n = file.readAll(&content_buf) catch return null;
    const content = content_buf[0..n];

    var start: usize = 0;
    while (start < content.len) {
        const eol = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        const entry_line = content[start..eol];
        start = eol + 1;

        if (parseEntry(entry_line)) |entry| {
            if (std.mem.eql(u8, entry.path, abs_path)) {
                return .{ .line = entry.line, .col = entry.col };
            }
        }
    }
    return null;
}

fn ensureCacheDir(positions_path: []const u8) void {
    const last_slash = std.mem.lastIndexOfScalar(u8, positions_path, '/') orelse return;
    std.fs.cwd().makePath(positions_path[0..last_slash]) catch {};
}

/// Record `line`/`col` for `abs_path`. The updated entry goes to the top
/// of the positions file; any prior entry for the same path is dropped,
/// and the tail is truncated to `max_entries`. Silently no-ops on any
/// I/O error.
pub fn record(abs_path: []const u8, line: usize, col: usize) void {
    if (abs_path.len == 0) return;
    // Paths with embedded newlines would corrupt the file format.
    if (std.mem.indexOfScalar(u8, abs_path, '\n') != null) return;

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const positions_path = resolveFilePath(&path_buf) orelse return;

    ensureCacheDir(positions_path);

    // Read existing file (may not exist).
    var in_buf: [file_cap]u8 = undefined;
    var in_len: usize = 0;
    if (std.fs.cwd().openFile(positions_path, .{})) |f| {
        defer f.close();
        in_len = f.readAll(&in_buf) catch 0;
    } else |_| {}

    // Build updated file: new entry first, then every old entry whose
    // path is not `abs_path`, honoring the entry cap.
    var out_buf: [file_cap]u8 = undefined;
    var out_len: usize = 0;

    const first = std.fmt.bufPrint(
        out_buf[out_len..],
        "{s}\t{d}\t{d}\n",
        .{ abs_path, line, col },
    ) catch return;
    out_len += first.len;

    var entry_count: usize = 1;
    var scan: usize = 0;
    while (scan < in_len and entry_count < max_entries) {
        const eol = std.mem.indexOfScalarPos(u8, in_buf[0..in_len], scan, '\n') orelse in_len;
        const entry_line = in_buf[scan..eol];
        scan = eol + 1;

        const parsed = parseEntry(entry_line) orelse continue;
        if (std.mem.eql(u8, parsed.path, abs_path)) continue;

        const needed = entry_line.len + 1;
        if (out_len + needed > out_buf.len) break;
        @memcpy(out_buf[out_len..][0..entry_line.len], entry_line);
        out_buf[out_len + entry_line.len] = '\n';
        out_len += needed;
        entry_count += 1;
    }

    // Atomic write: positions.txt.tmp + rename. Same pattern buffer.zig
    // uses for buffer saves so a crash mid-write can't corrupt the
    // existing file.
    var tmp_path_buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const tmp_path = std.fmt.bufPrint(
        &tmp_path_buf,
        "{s}.tmp",
        .{positions_path},
    ) catch return;

    const tmp_file = std.fs.cwd().createFile(tmp_path, .{ .truncate = true }) catch return;
    {
        defer tmp_file.close();
        tmp_file.writeAll(out_buf[0..out_len]) catch {
            std.fs.cwd().deleteFile(tmp_path) catch {};
            return;
        };
    }
    std.fs.cwd().rename(tmp_path, positions_path) catch {
        std.fs.cwd().deleteFile(tmp_path) catch {};
    };
}

// ── Test helpers ──

// std.c doesn't surface setenv/unsetenv in 0.15, so declare the C ABI
// shims ourselves. Only used by the round-trip test below.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

// ── Tests ──

test "parseEntry happy path" {
    const e = parseEntry("/foo/bar\t42\t7").?;
    try std.testing.expectEqualSlices(u8, "/foo/bar", e.path);
    try std.testing.expectEqual(@as(usize, 42), e.line);
    try std.testing.expectEqual(@as(usize, 7), e.col);
}

test "parseEntry handles tabs in path" {
    const e = parseEntry("/weird\tpath\t3\t4").?;
    try std.testing.expectEqualSlices(u8, "/weird\tpath", e.path);
    try std.testing.expectEqual(@as(usize, 3), e.line);
    try std.testing.expectEqual(@as(usize, 4), e.col);
}

test "parseEntry rejects malformed lines" {
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry(""));
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry("/no/tabs"));
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry("/one\ttab"));
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry("/path\tnot_a_number\t5"));
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry("/path\t5\tnot_a_number"));
    try std.testing.expectEqual(@as(?ParsedEntry, null), parseEntry("\t5\t6"));
}

test "lookup returns null for empty path" {
    try std.testing.expectEqual(@as(?Position, null), lookup(""));
}

test "record + lookup round-trip under a scratch HOME" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var home_buf: [std.fs.max_path_bytes]u8 = undefined;
    const home = try tmp.dir.realpath(".", &home_buf);

    // Swap HOME for the scope of this test. std.posix.setenv hits the
    // process environment, which is OK inside a test binary.
    var home_z: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(home_z[0..home.len], home);
    home_z[home.len] = 0;

    const prev = std.posix.getenv("HOME");
    _ = setenv("HOME", home_z[0..home.len :0].ptr, 1);
    defer {
        if (prev) |p| {
            var prev_z: [std.fs.max_path_bytes + 1]u8 = undefined;
            @memcpy(prev_z[0..p.len], p);
            prev_z[p.len] = 0;
            _ = setenv("HOME", prev_z[0..p.len :0].ptr, 1);
        } else {
            _ = unsetenv("HOME");
        }
    }

    record("/my/file.zig", 42, 7);
    const pos = lookup("/my/file.zig") orelse return error.LookupMissed;
    try std.testing.expectEqual(@as(usize, 42), pos.line);
    try std.testing.expectEqual(@as(usize, 7), pos.col);

    // Re-record with different numbers — the top entry wins.
    record("/my/file.zig", 9, 2);
    const pos2 = lookup("/my/file.zig") orelse return error.LookupMissed;
    try std.testing.expectEqual(@as(usize, 9), pos2.line);
    try std.testing.expectEqual(@as(usize, 2), pos2.col);

    // Second path coexists independently.
    record("/other.md", 1, 1);
    const first_again = lookup("/my/file.zig") orelse return error.LookupMissed;
    try std.testing.expectEqual(@as(usize, 9), first_again.line);

    // Paths not in the file miss cleanly.
    try std.testing.expectEqual(@as(?Position, null), lookup("/never/saved"));
}
