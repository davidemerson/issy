//! Gap buffer text storage.
//!
//! The core data structure for text editing. Uses a gap buffer for efficient
//! insert and delete operations near the cursor. Supports loading and saving
//! files, line-based access, and full content extraction.

const std = @import("std");
const Allocator = std.mem.Allocator;

const initial_capacity = 4096;
const min_gap = 64;

/// A gap buffer for efficient text editing operations.
pub const Buffer = struct {
    data: []u8,
    gap_start: usize,
    gap_end: usize,
    allocator: Allocator,
    dirty: bool,
    line_count_cache: ?usize,

    /// Create a new empty buffer with initial capacity 4096.
    pub fn init(allocator: Allocator) !Buffer {
        const data = try allocator.alloc(u8, initial_capacity);
        return .{
            .data = data,
            .gap_start = 0,
            .gap_end = initial_capacity,
            .allocator = allocator,
            .dirty = false,
            .line_count_cache = 1,
        };
    }

    /// Free all resources owned by this buffer.
    pub fn deinit(self: *Buffer) void {
        self.allocator.free(self.data);
    }

    /// Load file contents into the buffer, replacing any existing content.
    pub fn load(self: *Buffer, path: []const u8) !void {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const file_size: usize = @intCast(stat.size);

        const capacity = @max(file_size + min_gap, initial_capacity);
        self.allocator.free(self.data);
        self.data = try self.allocator.alloc(u8, capacity);

        const bytes_read = try file.readAll(self.data[0..file_size]);
        self.gap_start = bytes_read;
        self.gap_end = capacity;
        self.dirty = false;
        self.line_count_cache = null;
    }

    /// Save buffer contents to a file atomically (write .tmp then rename).
    pub fn save(self: *Buffer, path: []const u8) !void {
        // Build tmp path: path ++ ".tmp"
        var tmp_buf: [4096]u8 = undefined;
        if (path.len + 4 > tmp_buf.len) return error.PathTooLong;
        @memcpy(tmp_buf[0..path.len], path);
        @memcpy(tmp_buf[path.len..][0..4], ".tmp");
        const tmp_path = tmp_buf[0 .. path.len + 4];

        // Determine the directory for the file.
        const dir = std.fs.cwd();

        const tmp_file = try dir.createFile(tmp_path, .{});
        errdefer {
            tmp_file.close();
            dir.deleteFile(tmp_path) catch {};
        }

        // Write content before gap.
        if (self.gap_start > 0) {
            try tmp_file.writeAll(self.data[0..self.gap_start]);
        }
        // Write content after gap.
        if (self.gap_end < self.data.len) {
            try tmp_file.writeAll(self.data[self.gap_end..]);
        }
        tmp_file.close();

        // Atomic rename.
        try dir.rename(tmp_path, path);
        self.dirty = false;
    }

    /// Insert text at the given byte position.
    pub fn insert(self: *Buffer, pos: usize, text: []const u8) !void {
        if (text.len == 0) return;

        try self.ensureGap(text.len);
        self.moveGap(pos);

        @memcpy(self.data[self.gap_start..][0..text.len], text);
        self.gap_start += text.len;
        self.dirty = true;
        self.line_count_cache = null;
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
        self.line_count_cache = null;
    }

    /// Return the byte at the given logical position.
    pub fn byteAt(self: *const Buffer, pos: usize) u8 {
        return self.data[self.logicalToPhysical(pos)];
    }

    /// Total content length (allocation size minus gap size).
    pub fn logicalLen(self: *const Buffer) usize {
        return self.data.len - (self.gap_end - self.gap_start);
    }

    /// Count newlines + 1. Caches the result; cache is invalidated on edit.
    pub fn lineCount(self: *Buffer) usize {
        if (self.line_count_cache) |cached| return cached;

        var count: usize = 1;
        const len = self.logicalLen();
        for (0..len) |i| {
            if (self.byteAt(i) == '\n') count += 1;
        }
        self.line_count_cache = count;
        return count;
    }

    /// Return byte offset and length of the nth line (0-indexed).
    pub fn getLine(self: *Buffer, n: usize) ?struct { start: usize, len: usize } {
        const total = self.logicalLen();
        var line: usize = 0;
        var line_start: usize = 0;

        if (n == 0) {
            // Find end of first line.
            for (0..total) |i| {
                if (self.byteAt(i) == '\n') {
                    return .{ .start = 0, .len = i };
                }
            }
            return .{ .start = 0, .len = total };
        }

        for (0..total) |i| {
            if (self.byteAt(i) == '\n') {
                line += 1;
                if (line == n) {
                    line_start = i + 1;
                    // Find end of this line.
                    var j = line_start;
                    while (j < total) : (j += 1) {
                        if (self.byteAt(j) == '\n') {
                            return .{ .start = line_start, .len = j - line_start };
                        }
                    }
                    return .{ .start = line_start, .len = total - line_start };
                }
            }
        }
        return null;
    }

    /// If the range does not cross the gap, return a direct slice (zero-copy).
    /// If it crosses the gap, copy into tmp and return that.
    pub fn contiguousSlice(self: *const Buffer, start: usize, len: usize, tmp: []u8) []const u8 {
        if (len == 0) return self.data[0..0];

        const end = start + len; // exclusive
        // The range crosses the gap if it straddles gap_start.
        if (start < self.gap_start and end > self.gap_start) {
            // Crosses gap — copy into tmp.
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

    // Write test file.
    const file = try tmp_dir.dir.createFile("test.txt", .{});
    try file.writeAll(test_content);
    file.close();

    // Get the real path for load/save.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real_path = try tmp_dir.dir.realpath("test.txt", &path_buf);

    try buf.load(real_path);
    try std.testing.expectEqual(@as(usize, test_content.len), buf.logicalLen());
    try std.testing.expect(!buf.dirty);

    const c = try buf.contents(std.testing.allocator);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualStrings(test_content, c);

    // Modify and save back to the same file.
    try buf.insert(0, "NEW: ");
    try buf.save(real_path);
    try std.testing.expect(!buf.dirty);

    // Read back and verify.
    const saved_file = try tmp_dir.dir.openFile("test.txt", .{});
    defer saved_file.close();
    const saved = try saved_file.readToEndAlloc(std.testing.allocator, 1024 * 1024);
    defer std.testing.allocator.free(saved);
    try std.testing.expectEqualStrings("NEW: line one\nline two\nline three\n", saved);
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
