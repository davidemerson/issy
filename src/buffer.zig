//! Gap buffer text storage.
//!
//! The core data structure for text editing. Uses a gap buffer for efficient
//! insert and delete operations near the cursor. Supports loading and saving
//! files, line-based access, and full content extraction.
//!
//! Line access is O(1) via a lazily-rebuilt line index: an array of byte
//! offsets, one per line start. Any edit invalidates the index; the next
//! line query rebuilds it with a single memchr-style scan over the two gap
//! segments. This keeps per-frame rendering O(visible rows) instead of
//! O(visible rows × file size).
//!
//! Files whose lines all end in CRLF are normalized to LF in memory on
//! load and written back with CRLF on save, so Windows-authored files
//! round-trip without the editor showing stray carriage returns. Files
//! with mixed endings are left byte-for-byte untouched.

const std = @import("std");
const fsx = @import("fsx.zig");
const Allocator = std.mem.Allocator;

const initial_capacity = 4096;
const min_gap = 64;

pub const LineEnding = enum { lf, crlf };

/// A gap buffer for efficient text editing operations.
pub const Buffer = struct {
    data: []u8,
    gap_start: usize,
    gap_end: usize,
    allocator: Allocator,
    dirty: bool,
    /// Detected on load; save() re-applies it. Pure-CRLF files are
    /// normalized to LF in memory.
    line_ending: LineEnding,
    /// Byte offset of the start of each line. items[0] is always 0.
    /// Rebuilt lazily after any edit.
    line_index: std.ArrayList(usize),
    line_index_valid: bool,
    /// Smallest byte position touched by an edit since the last call to
    /// takeDirtyMinPos(). Consumed by the renderer to invalidate its
    /// per-line syntax-state cache.
    dirty_min_pos: ?usize,

    /// Create a new empty buffer with initial capacity 4096.
    pub fn init(allocator: Allocator) !Buffer {
        const data = try allocator.alloc(u8, initial_capacity);
        return .{
            .data = data,
            .gap_start = 0,
            .gap_end = initial_capacity,
            .allocator = allocator,
            .dirty = false,
            .line_ending = .lf,
            .line_index = .empty,
            .line_index_valid = false,
            .dirty_min_pos = null,
        };
    }

    /// Free all resources owned by this buffer.
    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
        self.line_index.deinit(self.allocator);
    }

    /// Load file contents into the buffer, replacing any existing content.
    /// Allocates the replacement backing array before freeing the old one,
    /// so an allocation failure leaves the buffer untouched.
    pub fn load(self: *Buffer, path: []const u8) !void {
        const file = try fsx.openFile(path);
        defer file.close();

        const stat = try file.stat();
        const file_size: usize = @intCast(stat.size);

        const capacity = @max(file_size + min_gap, initial_capacity);
        const new_data = try self.allocator.alloc(u8, capacity);
        errdefer self.allocator.free(new_data);

        const bytes_read = try file.readAll(new_data[0..file_size]);

        self.allocator.free(self.data);
        self.data = new_data;

        var content_len = bytes_read;
        self.line_ending = .lf;
        if (isPureCrlf(new_data[0..content_len])) {
            content_len = stripCrBeforeLf(new_data[0..content_len]);
            self.line_ending = .crlf;
        }

        self.gap_start = content_len;
        self.gap_end = capacity;
        self.dirty = false;
        self.invalidateFrom(0);
    }

    /// Save buffer contents to a file atomically (write a unique temp
    /// sibling, fsync, then rename over the target). Follows symlinks so
    /// saving through a link rewrites the target file instead of replacing
    /// the link itself, and preserves the original file's permission bits.
    /// File data is fsynced before the rename, so after a crash the path
    /// holds either the complete old or the complete new contents — and a
    /// failed sync aborts the save (temp removed, original untouched)
    /// instead of renaming a possibly-truncated temp into place. A
    /// best-effort directory fsync afterward makes the rename itself
    /// durable. CRLF line endings detected at load time are re-applied
    /// on the way out.
    pub fn save(self: *Buffer, path: []const u8) !void {
        var link_buf: [fsx.max_path_bytes]u8 = undefined;
        const target = resolveSymlinks(path, &link_buf);

        // Capture the original permission bits (if the file exists) so the
        // rename doesn't silently reset them to the umask default.
        const orig_mode: ?u32 = blk: {
            const st = fsx.statFile(target) catch break :blk null;
            break :blk st.mode;
        };

        // Unique hidden temp in the same directory (rename must stay on
        // one filesystem): "<dir>/.<basename>.<8 hex>.issy-tmp". O_EXCL
        // refuses to open through a planted symlink and never clobbers an
        // existing file (a user's real "foo.tmp" included), and the random
        // suffix keeps two issy instances saving the same file from racing
        // over one temp name. An existing target's temp starts private
        // (0600) until fchmod copies the real bits — no window where old
        // content is exposed under wider permissions; a brand-new file
        // keeps the umask-mediated default the old code had.
        var tmp_buf: [fsx.max_path_bytes + 32]u8 = undefined;
        var tmp_file: fsx.File = undefined;
        var tmp_path: []const u8 = undefined;
        var attempt: u8 = 0;
        while (true) : (attempt += 1) {
            var rand: [4]u8 = undefined;
            std.crypto.random.bytes(&rand);
            const hex = std.fmt.bytesToHex(rand, .lower);
            tmp_path = if (std.fs.path.dirname(target)) |dir|
                std.fmt.bufPrint(&tmp_buf, "{s}/.{s}.{s}.issy-tmp", .{
                    dir, std.fs.path.basename(target), &hex,
                }) catch return error.PathTooLong
            else
                std.fmt.bufPrint(&tmp_buf, ".{s}.{s}.issy-tmp", .{
                    std.fs.path.basename(target), &hex,
                }) catch return error.PathTooLong;
            tmp_file = fsx.createFile(tmp_path, .{
                .exclusive = true,
                .mode = if (orig_mode != null) 0o600 else 0o666,
            }) catch |e| switch (e) {
                error.PathAlreadyExists => if (attempt < 2) continue else return e,
                else => return e,
            };
            break;
        }
        var tmp_open = true;
        errdefer {
            if (tmp_open) tmp_file.close();
            fsx.deleteFile(tmp_path) catch {};
        }

        if (orig_mode) |m| {
            _ = std.c.fchmod(tmp_file.handle, @intCast(m & 0o7777));
        }

        try self.writeContents(tmp_file);
        // Flush file data to disk before the rename. With delayed
        // allocation a full disk or I/O error often surfaces here rather
        // than at write(); propagating it is what keeps a truncated temp
        // from being renamed over the good original while the editor
        // reports success. (close() can't report errors on either Zig
        // version; syncing first is what makes that acceptable.)
        try tmp_file.sync();
        tmp_file.close();
        tmp_open = false;

        // Atomic rename, then best-effort directory fsync so the new
        // directory entry survives a crash right after the save.
        try fsx.rename(tmp_path, target);
        fsx.syncDirOf(target);
        self.dirty = false;
    }

    fn writeContents(self: *const Buffer, file: fsx.File) !void {
        if (self.line_ending == .lf) {
            if (self.gap_start > 0) try file.writeAll(self.data[0..self.gap_start]);
            if (self.gap_end < self.data.len) try file.writeAll(self.data[self.gap_end..]);
            return;
        }
        try writeSegmentCrlf(file, self.data[0..self.gap_start]);
        try writeSegmentCrlf(file, self.data[self.gap_end..]);
    }

    fn writeSegmentCrlf(file: fsx.File, seg: []const u8) !void {
        var i: usize = 0;
        while (i < seg.len) {
            const nl = std.mem.indexOfScalarPos(u8, seg, i, '\n') orelse {
                try file.writeAll(seg[i..]);
                return;
            };
            if (nl > i) try file.writeAll(seg[i..nl]);
            try file.writeAll("\r\n");
            i = nl + 1;
        }
    }

    /// Insert text at the given byte position.
    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        if (text.len == 0) return;

        try self.ensureGap(text.len);
        self.moveGap(pos);

        @memcpy(self.data[self.gap_start..][0..text.len], text);
        self.gap_start += text.len;
        self.dirty = true;
        self.invalidateFrom(pos);
    }

    /// Delete `len` bytes starting at `pos`.
    pub fn delete(self: *Buffer, pos: usize, len: usize) void {
        if (len == 0) return;

        self.moveGap(pos);
        self.gap_end += len;
        // Clamp to end of buffer.
        if (self.gap_end > self.data.len) {
            self.gap_end = self.data.len;
        }
        self.dirty = true;
        self.invalidateFrom(pos);
    }

    /// Return the byte at the given logical position.
    pub fn byteAt(self: *const Buffer, pos: usize) u8 {
        return self.data[self.logicalToPhysical(pos)];
    }

    /// Total content length (allocation size minus gap size).
    pub fn logicalLen(self: *const Buffer) usize {
        return self.data.len - (self.gap_end - self.gap_start);
    }

    /// Number of lines (newline count + 1). O(1) via the line index.
    pub fn lineCount(self: *Buffer) usize {
        self.ensureLineIndex();
        return self.line_index.items.len;
    }

    /// Return byte offset and length of the nth line (0-indexed),
    /// excluding the trailing newline. O(1) via the line index.
    pub fn getLine(self: *Buffer, n: usize) ?struct { start: usize, len: usize } {
        self.ensureLineIndex();
        const items = self.line_index.items;
        if (n >= items.len) return null;
        const start = items[n];
        const end = if (n + 1 < items.len) items[n + 1] - 1 else self.logicalLen();
        return .{ .start = start, .len = end - start };
    }

    /// Return the 0-indexed line containing byte position `pos`.
    /// Positions at or past the end map to the last line. O(log lines).
    pub fn lineOfPos(self: *Buffer, pos: usize) usize {
        self.ensureLineIndex();
        const items = self.line_index.items;
        // Binary search: first index with items[i] > pos, minus one.
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] <= pos) lo = mid + 1 else hi = mid;
        }
        return if (lo == 0) 0 else lo - 1;
    }

    /// Return and clear the smallest byte position edited since the last
    /// call. Used by the renderer's syntax-state cache.
    pub fn takeDirtyMinPos(self: *Buffer) ?usize {
        const p = self.dirty_min_pos;
        self.dirty_min_pos = null;
        return p;
    }

    /// Find the first occurrence of `pattern` at or after logical position
    /// `from`. Searches the two gap segments directly (no per-byte calls)
    /// plus a small stitched window across the gap boundary. Patterns
    /// longer than 256 bytes are only matched when they don't straddle
    /// the gap. With `ignore_case`, matching is ASCII case-insensitive.
    pub fn find(self: *const Buffer, pattern: []const u8, from: usize, ignore_case: bool) ?usize {
        const m = pattern.len;
        if (m == 0) return null;
        const total = self.logicalLen();
        if (from + m > total) return null;

        const pre = self.data[0..self.gap_start];
        const post = self.data[self.gap_end..];

        // 1. Fully inside the pre-gap segment.
        if (from < pre.len) {
            if (indexOfPos(pre, from, pattern, ignore_case)) |idx| return idx;
        }

        // 2. Straddling the gap boundary.
        if (m > 1 and m <= 256 and pre.len > 0 and post.len > 0) {
            const k = @min(m - 1, pre.len);
            const tail = @min(m - 1, post.len);
            var stitched: [510]u8 = undefined;
            @memcpy(stitched[0..k], pre[pre.len - k ..]);
            @memcpy(stitched[k..][0..tail], post[0..tail]);
            const win_start = pre.len - k; // logical offset of stitched[0]
            const search_from = if (from > win_start) from - win_start else 0;
            if (search_from < k) {
                if (indexOfPos(stitched[0 .. k + tail], search_from, pattern, ignore_case)) |idx| {
                    if (idx < k) return win_start + idx;
                }
            }
        }

        // 3. Fully inside the post-gap segment.
        const post_from = if (from > pre.len) from - pre.len else 0;
        if (indexOfPos(post, post_from, pattern, ignore_case)) |idx| {
            return pre.len + idx;
        }
        return null;
    }

    /// If the range does not cross the gap, return a direct slice (zero-copy).
    /// If it crosses the gap, copy into tmp and return that. When the range
    /// crosses the gap, `tmp` must be at least `len` bytes.
    pub fn contiguousSlice(self: *const Buffer, start: usize, len: usize, tmp: []u8) []const u8 {
        if (len == 0) return self.data[0..0];

        const end = start + len; // exclusive
        // The range crosses the gap if it straddles gap_start.
        if (start < self.gap_start and end > self.gap_start) {
            // Crosses gap — copy into tmp.
            std.debug.assert(len <= tmp.len);
            const pre = self.gap_start - start;
            @memcpy(tmp[0..pre], self.data[start..self.gap_start]);
            const post = end - self.gap_start;
            @memcpy(tmp[pre..][0..post], self.data[self.gap_end..][0..post]);
            return tmp[0..len];
        }

        // Contiguous — return a direct slice.
        const phys_start = self.logicalToPhysical(start);
        return self.data[phys_start .. phys_start + len];
    }

    /// Allocate a contiguous copy of the buffer contents.
    pub fn contents(self: *const Buffer, allocator: Allocator) ![]u8 {
        const len = self.logicalLen();
        const result = try allocator.alloc(u8, len);

        // Copy pre-gap content.
        const pre_gap = self.gap_start;
        if (pre_gap > 0) {
            @memcpy(result[0..pre_gap], self.data[0..pre_gap]);
        }
        // Copy post-gap content.
        const post_gap = self.data.len - self.gap_end;
        if (post_gap > 0) {
            @memcpy(result[pre_gap..][0..post_gap], self.data[self.gap_end..]);
        }
        return result;
    }

    // --- Private helpers ---

    fn invalidateFrom(self: *Buffer, pos: usize) void {
        self.line_index_valid = false;
        self.dirty_min_pos = if (self.dirty_min_pos) |p| @min(p, pos) else pos;
    }

    fn ensureLineIndex(self: *Buffer) void {
        if (self.line_index_valid) return;
        self.line_index.clearRetainingCapacity();
        // On allocation failure we bail with whatever fit; the flag stays
        // false so the next call retries.
        self.line_index.append(self.allocator, 0) catch return;

        const pre = self.data[0..self.gap_start];
        var i: usize = 0;
        while (std.mem.indexOfScalarPos(u8, pre, i, '\n')) |nl| {
            self.line_index.append(self.allocator, nl + 1) catch return;
            i = nl + 1;
        }

        const post = self.data[self.gap_end..];
        i = 0;
        while (std.mem.indexOfScalarPos(u8, post, i, '\n')) |nl| {
            // Physical gap_end + nl → logical gap_start + nl.
            self.line_index.append(self.allocator, self.gap_start + nl + 1) catch return;
            i = nl + 1;
        }
        self.line_index_valid = true;
    }

    fn logicalToPhysical(self: *const Buffer, pos: usize) usize {
        if (pos < self.gap_start) return pos;
        return pos + (self.gap_end - self.gap_start);
    }

    fn gapLen(self: *const Buffer) usize {
        return self.gap_end - self.gap_start;
    }

    fn moveGap(self: *Buffer, pos: usize) void {
        if (pos == self.gap_start) return;

        if (pos < self.gap_start) {
            // Move gap left: shift data[pos..gap_start] to end of gap.
            const count = self.gap_start - pos;
            std.mem.copyBackwards(u8, self.data[self.gap_end - count .. self.gap_end], self.data[pos..self.gap_start]);
            self.gap_start = pos;
            self.gap_end -= count;
        } else {
            // Move gap right: shift data[gap_end..gap_end+count] to gap_start.
            const count = pos - self.gap_start;
            std.mem.copyForwards(u8, self.data[self.gap_start .. self.gap_start + count], self.data[self.gap_end .. self.gap_end + count]);
            self.gap_start += count;
            self.gap_end += count;
        }
    }

    fn ensureGap(self: *Buffer, needed: usize) !void {
        if (self.gapLen() >= needed and self.gapLen() >= min_gap) return;

        const content_len = self.logicalLen();
        var new_capacity = self.data.len;
        while (new_capacity - content_len < @max(needed, min_gap)) {
            new_capacity *= 2;
        }

        const new_data = try self.allocator.alloc(u8, new_capacity);

        // Copy pre-gap.
        if (self.gap_start > 0) {
            @memcpy(new_data[0..self.gap_start], self.data[0..self.gap_start]);
        }
        // Copy post-gap to end of new allocation.
        const post_gap = self.data.len - self.gap_end;
        if (post_gap > 0) {
            @memcpy(new_data[new_capacity - post_gap ..], self.data[self.gap_end..]);
        }

        self.allocator.free(self.data);
        self.data = new_data;
        self.gap_end = new_capacity - post_gap;
    }
};

fn indexOfPos(haystack: []const u8, start: usize, needle: []const u8, ignore_case: bool) ?usize {
    if (start >= haystack.len) return null;
    if (ignore_case) {
        const idx = std.ascii.indexOfIgnoreCase(haystack[start..], needle) orelse return null;
        return start + idx;
    }
    return std.mem.indexOfPos(u8, haystack, start, needle);
}

/// True if the content contains at least one newline and every newline is
/// preceded by a carriage return (i.e., the file is uniformly CRLF).
fn isPureCrlf(content: []const u8) bool {
    var found = false;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, content, i, '\n')) |nl| {
        if (nl == 0 or content[nl - 1] != '\r') return false;
        found = true;
        i = nl + 1;
    }
    return found;
}

/// Remove every '\r' that directly precedes a '\n', in place.
/// Returns the new length.
fn stripCrBeforeLf(buf: []u8) usize {
    var w: usize = 0;
    var r: usize = 0;
    while (r < buf.len) : (r += 1) {
        if (buf[r] == '\r' and r + 1 < buf.len and buf[r + 1] == '\n') continue;
        buf[w] = buf[r];
        w += 1;
    }
    return w;
}

/// Follow up to 8 symlink hops and return the final target path (copied
/// into `out`). Relative link targets resolve against the link's own
/// directory. On any error (not a link, too many hops, path too long)
/// returns the deepest path resolved so far. Uses readlink(2) directly
/// instead of realpath, which is not portable to OpenBSD without libc.
fn resolveSymlinks(path: []const u8, out: *[fsx.max_path_bytes]u8) []const u8 {
    var bufs: [2][fsx.max_path_bytes]u8 = undefined;
    var scratch: [fsx.max_path_bytes]u8 = undefined;
    var cur: []const u8 = path;
    var flip: u1 = 0;
    var hops: u8 = 0;
    while (hops < 8) : (hops += 1) {
        const target = fsx.readLink(cur, &scratch) catch break;
        if (target.len == 0) break;
        const dst = &bufs[flip];
        var n: usize = 0;
        if (target[0] != '/') {
            if (std.mem.lastIndexOfScalar(u8, cur, '/')) |de| {
                if (de + 1 > dst.len) break;
                @memcpy(dst[0 .. de + 1], cur[0 .. de + 1]);
                n = de + 1;
            }
        }
        if (n + target.len > dst.len) break;
        @memcpy(dst[n..][0..target.len], target);
        cur = dst[0 .. n + target.len];
        flip +%= 1;
    }
    if (cur.ptr == path.ptr) return path;
    @memcpy(out[0..cur.len], cur);
    return out[0..cur.len];
}

// =============================================================================
// Tests
// =============================================================================

test "init and deinit" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.logicalLen());
    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
    try std.testing.expect(!buf.dirty);
}

test "insert at start" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello");
    try std.testing.expectEqual(@as(usize, 5), buf.logicalLen());
    try std.testing.expectEqual(@as(u8, 'h'), buf.byteAt(0));
    try std.testing.expectEqual(@as(u8, 'o'), buf.byteAt(4));
    try std.testing.expect(buf.dirty);
}

test "insert at end" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello");
    try buf.insert(5, " world");
    try std.testing.expectEqual(@as(usize, 11), buf.logicalLen());

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("hello world", c);
}

test "insert in middle" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "helo");
    try buf.insert(2, "l");

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("hello", c);
}

test "delete at start" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello");
    buf.delete(0, 2);

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("llo", c);
}

test "delete at end" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello");
    buf.delete(3, 2);

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("hel", c);
}

test "delete in middle" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello world");
    buf.delete(5, 1);

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("helloworld", c);
}

test "delete everything" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello");
    buf.delete(0, 5);
    try std.testing.expectEqual(@as(usize, 0), buf.logicalLen());
}

test "empty buffer edge cases" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try std.testing.expectEqual(@as(usize, 0), buf.logicalLen());
    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
    buf.delete(0, 0);
    try std.testing.expectEqual(@as(usize, 0), buf.logicalLen());

    // getLine on empty buffer: line 0 exists with length 0.
    const line0 = buf.getLine(0);
    try std.testing.expect(line0 != null);
    try std.testing.expectEqual(@as(usize, 0), line0.?.start);
    try std.testing.expectEqual(@as(usize, 0), line0.?.len);

    // No line 1.
    try std.testing.expect(buf.getLine(1) == null);
}

test "line counting" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "line1\nline2\nline3");
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());

    // With trailing newline.
    try buf.insert(buf.logicalLen(), "\n");
    try std.testing.expectEqual(@as(usize, 4), buf.lineCount());
}

test "line counting no trailing newline" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "single line");
    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());
}

test "getLine" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "aaa\nbb\nccccc");

    const l0 = buf.getLine(0).?;
    try std.testing.expectEqual(@as(usize, 0), l0.start);
    try std.testing.expectEqual(@as(usize, 3), l0.len);

    const l1 = buf.getLine(1).?;
    try std.testing.expectEqual(@as(usize, 4), l1.start);
    try std.testing.expectEqual(@as(usize, 2), l1.len);

    const l2 = buf.getLine(2).?;
    try std.testing.expectEqual(@as(usize, 7), l2.start);
    try std.testing.expectEqual(@as(usize, 5), l2.len);

    try std.testing.expect(buf.getLine(3) == null);
}

test "getLine with trailing newline" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello\n");
    const l0 = buf.getLine(0).?;
    try std.testing.expectEqual(@as(usize, 0), l0.start);
    try std.testing.expectEqual(@as(usize, 5), l0.len);

    const l1 = buf.getLine(1).?;
    try std.testing.expectEqual(@as(usize, 6), l1.start);
    try std.testing.expectEqual(@as(usize, 0), l1.len);
}

test "getLine stays correct while the gap moves" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "aaa\nbb\nccccc");
    // Move the gap into the middle by editing there.
    try buf.insert(4, "X");
    buf.delete(4, 1);

    const l1 = buf.getLine(1).?;
    try std.testing.expectEqual(@as(usize, 4), l1.start);
    try std.testing.expectEqual(@as(usize, 2), l1.len);
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
}

test "lineOfPos" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "aaa\nbb\nccccc");
    try std.testing.expectEqual(@as(usize, 0), buf.lineOfPos(0));
    try std.testing.expectEqual(@as(usize, 0), buf.lineOfPos(3)); // the newline itself
    try std.testing.expectEqual(@as(usize, 1), buf.lineOfPos(4));
    try std.testing.expectEqual(@as(usize, 2), buf.lineOfPos(7));
    try std.testing.expectEqual(@as(usize, 2), buf.lineOfPos(999)); // past end → last line
}

test "takeDirtyMinPos tracks the smallest edited position" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello world");
    _ = buf.takeDirtyMinPos();
    try buf.insert(6, "X");
    buf.delete(2, 1);
    try std.testing.expectEqual(@as(?usize, 2), buf.takeDirtyMinPos());
    try std.testing.expectEqual(@as(?usize, null), buf.takeDirtyMinPos());
}

test "find in pre-gap, post-gap, and across the gap" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "abc needle def needle ghi");
    // Park the gap between the two needles (inside " def ").
    try buf.insert(12, "X");
    buf.delete(12, 1);

    try std.testing.expectEqual(@as(?usize, 4), buf.find("needle", 0, false));
    try std.testing.expectEqual(@as(?usize, 15), buf.find("needle", 5, false));
    try std.testing.expectEqual(@as(?usize, null), buf.find("needle", 16, false));
    try std.testing.expectEqual(@as(?usize, null), buf.find("missing", 0, false));

    // Pattern straddling the gap: gap sits at 12, "def" spans 11..14.
    try std.testing.expectEqual(@as(?usize, 11), buf.find("def", 0, false));
}

test "find case-insensitive" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "Hello World");
    try std.testing.expectEqual(@as(?usize, 6), buf.find("world", 0, true));
    try std.testing.expectEqual(@as(?usize, null), buf.find("world", 0, false));
}

test "contiguousSlice no gap crossing" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello world");
    // Gap is right after the inserted text; reading from start won't cross.
    var tmp: [64]u8 = undefined;
    const slice = buf.contiguousSlice(0, 5, &tmp);
    try std.testing.expectEqualStrings("hello", slice);
}

test "contiguousSlice across gap" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "hello world");
    // Move gap into the middle by inserting.
    try buf.insert(5, "X");
    // Now delete the X to leave gap at 5.
    buf.delete(5, 1);
    // "hello world" with gap at position 5.
    var tmp: [64]u8 = undefined;
    const slice = buf.contiguousSlice(3, 6, &tmp);
    try std.testing.expectEqualStrings("lo wor", slice);
}

test "contiguousSlice empty" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    var tmp: [64]u8 = undefined;
    const slice = buf.contiguousSlice(0, 0, &tmp);
    try std.testing.expectEqual(@as(usize, 0), slice.len);
}

test "load and save round-trip" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    const test_content = "line one\nline two\nline three\n";

    // Use std.testing.tmpDir for isolated temp directory.
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    // Build absolute path to the test file.  Avoid Dir.realpath which
    // is unsupported on OpenBSD; the tmpDir lives under
    // .zig-cache/tmp/<sub_path> relative to cwd.
    var path_buf: [fsx.max_path_bytes]u8 = undefined;
    const cwd = try fsx.getcwd(&path_buf);
    const real_path = try std.fmt.bufPrint(
        path_buf[cwd.len..],
        "/.zig-cache/tmp/{s}/test.txt",
        .{&tmp_dir.sub_path},
    );
    // bufPrint wrote into path_buf starting at cwd.len; the full
    // absolute path is path_buf[0 .. cwd.len + real_path.len].
    const real_path_full = path_buf[0 .. cwd.len + real_path.len];

    // Write test file.
    {
        const file = try fsx.createFile(real_path_full, .{});
        defer file.close();
        try file.writeAll(test_content);
    }

    try buf.load(real_path_full);
    try std.testing.expectEqual(@as(usize, test_content.len), buf.logicalLen());
    try std.testing.expect(!buf.dirty);

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings(test_content, c);

    // Modify and save back to the same file.
    try buf.insert(0, "NEW: ");
    try buf.save(real_path_full);
    try std.testing.expect(!buf.dirty);

    // Read back and verify.
    const saved = try fsx.readFileAlloc(std.testing.allocator, real_path_full, 1024 * 1024);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("NEW: line one\nline two\nline three\n", saved);
}

test "CRLF file normalizes on load and round-trips on save" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [fsx.max_path_bytes]u8 = undefined;
    const cwd = try fsx.getcwd(&path_buf);
    const rel = try std.fmt.bufPrint(
        path_buf[cwd.len..],
        "/.zig-cache/tmp/{s}/dos.txt",
        .{&tmp_dir.sub_path},
    );
    const full = path_buf[0 .. cwd.len + rel.len];

    {
        const file = try fsx.createFile(full, .{});
        defer file.close();
        try file.writeAll("one\r\ntwo\r\nthree\r\n");
    }

    try buf.load(full);
    try std.testing.expectEqual(LineEnding.crlf, buf.line_ending);

    // In memory: LF only.
    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("one\ntwo\nthree\n", c);
    try std.testing.expectEqual(@as(usize, 4), buf.lineCount());

    // Edit and save: CRLF comes back.
    try buf.insert(0, "zero\n");
    try buf.save(full);

    const saved = try fsx.readFileAlloc(std.testing.allocator, full, 1024);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("zero\r\none\r\ntwo\r\nthree\r\n", saved);
}

test "mixed line endings are left untouched" {
    try std.testing.expect(!isPureCrlf("a\r\nb\nc\r\n"));
    try std.testing.expect(!isPureCrlf("plain\nlf\n"));
    try std.testing.expect(isPureCrlf("a\r\nb\r\n"));
    try std.testing.expect(!isPureCrlf("no newline at all"));
}

test "save preserves permission bits" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [fsx.max_path_bytes]u8 = undefined;
    const cwd = try fsx.getcwd(&path_buf);
    const rel = try std.fmt.bufPrint(
        path_buf[cwd.len..],
        "/.zig-cache/tmp/{s}/exec.sh",
        .{&tmp_dir.sub_path},
    );
    const full = path_buf[0 .. cwd.len + rel.len];

    {
        const file = try fsx.createFile(full, .{ .mode = 0o755 });
        defer file.close();
        try file.writeAll("#!/bin/sh\n");
    }

    try buf.load(full);
    try buf.insert(buf.logicalLen(), "echo hi\n");
    try buf.save(full);

    const st = try fsx.statFile(full);
    try std.testing.expectEqual(@as(u32, 0o755), @as(u32, @intCast(st.mode & 0o7777)));
}

test "save through a symlink rewrites the target, not the link" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    var path_buf: [fsx.max_path_bytes]u8 = undefined;
    const cwd = try fsx.getcwd(&path_buf);
    const rel = try std.fmt.bufPrint(
        path_buf[cwd.len..],
        "/.zig-cache/tmp/{s}/link.txt",
        .{&tmp_dir.sub_path},
    );
    const full = path_buf[0 .. cwd.len + rel.len];

    var real_buf: [fsx.max_path_bytes]u8 = undefined;
    const cwd2 = try fsx.getcwd(&real_buf);
    const rel2 = try std.fmt.bufPrint(
        real_buf[cwd2.len..],
        "/.zig-cache/tmp/{s}/real.txt",
        .{&tmp_dir.sub_path},
    );
    const real_full = real_buf[0 .. cwd2.len + rel2.len];

    {
        const file = try fsx.createFile(real_full, .{});
        defer file.close();
        try file.writeAll("original\n");
    }
    try fsx.symLink("real.txt", full);

    try buf.load(full);
    try buf.insert(0, "edited ");
    try buf.save(full);

    // The link must still be a symlink…
    var lbuf: [fsx.max_path_bytes]u8 = undefined;
    const target = try fsx.readLink(full, &lbuf);
    try std.testing.expectEqualStrings("real.txt", target);

    // …and the target must hold the new content.
    const saved = try fsx.readFileAlloc(std.testing.allocator, real_full, 1024);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("edited original\n", saved);
}

test "save does not clobber a sibling .tmp file" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "content\n");

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [fsx.max_path_bytes]u8 = undefined;
    const cwd = try fsx.getcwd(&path_buf);
    const rel = try std.fmt.bufPrint(
        path_buf[cwd.len..],
        "/.zig-cache/tmp/{s}/doc.txt",
        .{&tmp_dir.sub_path},
    );
    const target = path_buf[0 .. cwd.len + rel.len];

    // A user file that happens to carry the old fixed temp suffix must
    // survive a save of its sibling untouched.
    var tmp_name_buf: [fsx.max_path_bytes]u8 = undefined;
    const bystander = try std.fmt.bufPrint(&tmp_name_buf, "{s}.tmp", .{target});
    {
        const f = try fsx.createFile(bystander, .{});
        defer f.close();
        try f.writeAll("sentinel");
    }

    try buf.save(target);

    const kept = try fsx.readFileAlloc(std.testing.allocator, bystander, 64);
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("sentinel", kept);
    const saved = try fsx.readFileAlloc(std.testing.allocator, target, 64);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("content\n", saved);
}

test "failed save propagates the error and leaves the target and directory intact" {
    // Root bypasses permission checks and the chmod setup below would
    // silently pass; skip there (some CI containers).
    if (std.c.geteuid() == 0) return error.SkipZigTest;

    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();
    try buf.insert(0, "new bytes that must not land\n");

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    var path_buf: [fsx.max_path_bytes]u8 = undefined;
    const cwd = try fsx.getcwd(&path_buf);
    const rel = try std.fmt.bufPrint(
        path_buf[cwd.len..],
        "/.zig-cache/tmp/{s}/ro",
        .{&tmp_dir.sub_path},
    );
    const dir_path = path_buf[0 .. cwd.len + rel.len];
    try fsx.makePath(dir_path);

    var target_buf: [fsx.max_path_bytes]u8 = undefined;
    const target = try std.fmt.bufPrint(&target_buf, "{s}/precious.txt", .{dir_path});
    {
        const f = try fsx.createFile(target, .{});
        defer f.close();
        try f.writeAll("precious");
    }

    var dir_z: [fsx.max_path_bytes]u8 = undefined;
    @memcpy(dir_z[0..dir_path.len], dir_path);
    dir_z[dir_path.len] = 0;
    _ = std.c.chmod(dir_z[0..dir_path.len :0], 0o500);
    defer _ = std.c.chmod(dir_z[0..dir_path.len :0], 0o700);

    // The temp can't be created in a read-only directory: the save must
    // fail loudly, not silently, and must not touch the original.
    try std.testing.expectError(error.AccessDenied, buf.save(target));

    _ = std.c.chmod(dir_z[0..dir_path.len :0], 0o700);
    const kept = try fsx.readFileAlloc(std.testing.allocator, target, 64);
    defer std.testing.allocator.free(kept);
    try std.testing.expectEqualStrings("precious", kept);

    // And no temp file may be left behind.
    var d = try fsx.openDirIterable(dir_path);
    defer d.close();
    var it = d.iterate();
    var count: usize = 0;
    while (try it.next()) |entry| {
        try std.testing.expectEqualStrings("precious.txt", entry.name);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "insert/delete sequence" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "abcdef");
    buf.delete(2, 2); // "abef"
    try buf.insert(2, "XY"); // "abXYef"

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("abXYef", c);
}

test "gap growth with large insert" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    // Insert more than initial capacity.
    const big = "a" ** 5000;
    try buf.insert(0, big);
    try std.testing.expectEqual(@as(usize, 5000), buf.logicalLen());

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings(big, c);
}

test "very long line" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    const long_line = "x" ** 10000;
    try buf.insert(0, long_line);
    try std.testing.expectEqual(@as(usize, 1), buf.lineCount());

    const line0 = buf.getLine(0).?;
    try std.testing.expectEqual(@as(usize, 10000), line0.len);
}

test "delete at boundaries" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "abc");
    // Delete nothing at start.
    buf.delete(0, 0);
    try std.testing.expectEqual(@as(usize, 3), buf.logicalLen());

    // Delete beyond end (clamped).
    buf.delete(2, 100);
    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings("ab", c);
}

test "line count cache invalidation" {
    var buf = try Buffer.init(std.testing.allocator);
    defer buf.deinit();

    try buf.insert(0, "a\nb\nc");
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());

    // Insert a newline — cache should be invalidated.
    try buf.insert(1, "\n");
    try std.testing.expectEqual(@as(usize, 4), buf.lineCount());

    // Delete a newline.
    buf.delete(1, 1);
    try std.testing.expectEqual(@as(usize, 3), buf.lineCount());
}
