//! Terminal I/O abstraction.
//!
//! Provides raw mode terminal input/output, key reading, cursor control,
//! color and style management, and screen operations. Abstracts over
//! platform-specific terminal APIs (termios on POSIX, Console API on Windows).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

/// Terminal color specification.
pub const Color = union(enum) {
    default,
    ansi: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
};

/// Cursor shape for the terminal.
pub const CursorShape = enum {
    bar,
    block,
    underline,
};

/// Key codes for terminal input.
pub const Key = union(enum) {
    char: u21,
    enter,
    tab,
    backspace,
    delete,
    escape,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    scroll_up,
    scroll_down,
    mouse_click: struct { row: u16, col: u16 },
    ctrl: u8,
    unknown,
    none,
};

/// Terminal size in rows and columns.
pub const Size = struct {
    rows: u16,
    cols: u16,
};

// ── Module state ──

const WRITE_BUF_SIZE = 16384;

var write_buf: [WRITE_BUF_SIZE]u8 = undefined;
var write_pos: usize = 0;
var cached_size: Size = .{ .rows = 24, .cols = 80 };
var truecolor_supported: bool = false;
var initialized: bool = false;

// Read-ahead buffer for input
const READ_BUF_SIZE = 256;
var read_buf: [READ_BUF_SIZE]u8 = undefined;
var read_start: usize = 0;
var read_end: usize = 0;

const is_posix = (builtin.os.tag == .linux or builtin.os.tag == .macos or
    builtin.os.tag == .openbsd or builtin.os.tag == .freebsd or
    builtin.os.tag == .netbsd);

var orig_termios: if (is_posix) posix.termios else void = if (is_posix) undefined else {};

/// Initialize the terminal for raw mode editing.
pub fn init() !void {
    if (is_posix) {
        const stdin_fd = std.fs.File.stdin().handle;

        orig_termios = try posix.tcgetattr(stdin_fd);

        var raw = orig_termios;

        // Input: disable break, CR-to-NL, parity, strip, flow control
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;

        // Output: disable post-processing
        raw.oflag.OPOST = false;

        // Control: 8-bit chars
        raw.cflag.CSIZE = .CS8;

        // Local: no echo, no canonical, no extended, no signals
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Read: 100ms timeout, return after any byte
        raw.cc[@intFromEnum(posix.V.MIN)] = 0;
        raw.cc[@intFromEnum(posix.V.TIME)] = 1;

        try posix.tcsetattr(stdin_fd, .FLUSH, raw);

        // Query terminal size
        updateSize();

        // Check truecolor support
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "COLORTERM")) |val| {
            truecolor_supported = std.mem.eql(u8, val, "truecolor") or std.mem.eql(u8, val, "24bit");
            std.heap.page_allocator.free(val);
        } else |_| {
            truecolor_supported = false;
        }

        // Enable mouse button events + SGR extended mouse format
        writeStr("\x1b[?1000h\x1b[?1006h");
        // Enter alternate screen
        writeStr("\x1b[?1049h");
        doFlush() catch {};
    }

    initialized = true;
}

/// Restore the terminal to its original state.
pub fn deinit() void {
    if (!initialized) return;

    if (is_posix) {
        // Restore cursor shape to terminal default
        writeStr("\x1b[0 q");
        // Disable mouse reporting
        writeStr("\x1b[?1000l\x1b[?1006l");
        // Leave alternate screen
        writeStr("\x1b[?1049l");
        // Reset styles
        writeStr("\x1b[0m");
        // Show cursor
        writeStr("\x1b[?25h");

        doFlush() catch {};

        const stdin_fd = std.fs.File.stdin().handle;
        posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};
    }

    initialized = false;
}

fn updateSize() void {
    if (is_posix) {
        const stdin_fd = std.fs.File.stdin().handle;
        var wsz: posix.winsize = undefined;
        const rc = posix.system.ioctl(stdin_fd, posix.T.IOCGWINSZ, @intFromPtr(&wsz));
        if (rc == 0) {
            if (wsz.row > 0) cached_size.rows = wsz.row;
            if (wsz.col > 0) cached_size.cols = wsz.col;
        }
    }
}

/// Query the current terminal dimensions.
pub fn getSize() Size {
    updateSize();
    return cached_size;
}

/// Read the next key event from terminal input.
pub fn readKey() !Key {
    if (is_posix) {
        return readKeyPosix();
    }
    return .none;
}

fn fillReadBuf() void {
    if (read_start >= read_end) {
        read_start = 0;
        read_end = 0;
    }
    const stdin = std.fs.File.stdin();
    const n = stdin.read(read_buf[read_end..]) catch 0;
    read_end += n;
}

fn readBufAvailable() usize {
    return read_end - read_start;
}

fn readBufPeek(offset: usize) u8 {
    return read_buf[read_start + offset];
}

fn readBufConsume(n: usize) void {
    read_start += n;
}

fn readBufSlice(start: usize, end: usize) []const u8 {
    return read_buf[read_start + start .. read_start + end];
}

fn readKeyPosix() !Key {
    // If no data in buffer, read from stdin
    if (readBufAvailable() == 0) {
        fillReadBuf();
        if (readBufAvailable() == 0) return .none;
    }

    const b = readBufPeek(0);

    // Special control chars
    if (b == 0x0d or b == 0x0a) {
        readBufConsume(1);
        return .enter;
    }
    if (b == 0x09) {
        readBufConsume(1);
        return .tab;
    }
    if (b == 0x7f) {
        readBufConsume(1);
        return .backspace;
    }

    // Other ctrl keys
    if (b < 0x20 and b != 0x1b) {
        readBufConsume(1);
        return .{ .ctrl = b + 'a' - 1 };
    }

    // Escape sequences
    if (b == 0x1b) {
        if (readBufAvailable() == 1) {
            // Only ESC in buffer — try to read more
            fillReadBuf();
            if (readBufAvailable() == 1) {
                readBufConsume(1);
                return .escape;
            }
        }
        const avail = readBufAvailable();
        const result = parseEscape(readBufSlice(0, avail));
        // Consume the escape sequence bytes
        const consumed = escapeLen(readBufSlice(0, avail));
        readBufConsume(consumed);
        return result;
    }

    // UTF-8 decode
    if (b < 0x80) {
        readBufConsume(1);
        return .{ .char = @intCast(b) };
    }

    // Multi-byte UTF-8
    const expected: usize = if (b < 0xC0) 1 else if (b < 0xE0) 2 else if (b < 0xF0) 3 else 4;
    if (expected <= readBufAvailable()) {
        const cp = decodeUtf8(readBufSlice(0, expected));
        readBufConsume(expected);
        return .{ .char = cp };
    }
    readBufConsume(1);
    return .unknown;
}

fn escapeLen(buf: []const u8) usize {
    // Determine how many bytes the escape sequence consumed
    if (buf.len < 2) return 1;
    // Only consume the next byte if it starts a real escape sequence (CSI)
    // Otherwise treat ESC as standalone — don't eat the following character
    if (buf[1] != '[') return 1;

    // CSI sequence: ESC [ ... <letter>
    var i: usize = 2;
    while (i < buf.len) {
        const c = buf[i];
        if ((c >= 0x40 and c <= 0x7E) and c != '[') {
            return i + 1; // include the terminator
        }
        i += 1;
    }
    return buf.len; // consume everything if no terminator found
}

fn decodeUtf8(bytes: []const u8) u21 {
    if (bytes.len == 0) return 0xFFFD;
    const b0 = bytes[0];
    if (b0 < 0x80) return @intCast(b0);
    if (bytes.len >= 2 and b0 >= 0xC0 and b0 < 0xE0) {
        return (@as(u21, b0 & 0x1F) << 6) | @as(u21, bytes[1] & 0x3F);
    }
    if (bytes.len >= 3 and b0 >= 0xE0 and b0 < 0xF0) {
        return (@as(u21, b0 & 0x0F) << 12) | (@as(u21, bytes[1] & 0x3F) << 6) | @as(u21, bytes[2] & 0x3F);
    }
    if (bytes.len >= 4 and b0 >= 0xF0) {
        return (@as(u21, b0 & 0x07) << 18) | (@as(u21, bytes[1] & 0x3F) << 12) | (@as(u21, bytes[2] & 0x3F) << 6) | @as(u21, bytes[3] & 0x3F);
    }
    return 0xFFFD;
}

fn parseEscape(buf: []const u8) Key {
    if (buf.len < 2) return .escape;
    if (buf[1] != '[') return .escape;
    if (buf.len < 3) return .escape;

    // SGR mouse: ESC [ < ...
    if (buf[2] == '<') {
        return parseSgrMouse(buf);
    }

    return switch (buf[2]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        '1' => parseExtended(buf),
        '2' => parseExtended(buf),
        '3' => parseExtended(buf),
        '4' => parseExtended(buf),
        '5' => if (buf.len >= 4 and buf[3] == '~') .page_up else .unknown,
        '6' => if (buf.len >= 4 and buf[3] == '~') .page_down else .unknown,
        else => .unknown,
    };
}

fn parseExtended(buf: []const u8) Key {
    if (buf.len < 4) return .unknown;

    // ESC [ 3 ~ = delete
    if (buf[2] == '3' and buf[3] == '~') return .delete;

    // ESC [ 1 ; 5 C = ctrl+right, ESC [ 1 ; 5 D = ctrl+left
    if (buf[2] == '1' and buf.len >= 6 and buf[3] == ';' and buf[4] == '5') {
        return switch (buf[5]) {
            'C' => .{ .ctrl = 'f' }, // ctrl+right -> word forward
            'D' => .{ .ctrl = 'b' }, // ctrl+left -> word backward
            else => .unknown,
        };
    }

    // ESC [ 1 ~ = home, ESC [ 4 ~ = end
    if (buf[3] == '~') {
        return switch (buf[2]) {
            '1' => .home,
            '4' => .end,
            else => .unknown,
        };
    }

    return .unknown;
}

fn parseSgrMouse(buf: []const u8) Key {
    // ESC [ < Cb ; Cx ; Cy M/m
    if (buf.len < 6) return .none;

    var pos: usize = 3; // skip ESC [ <
    var params: [3]u16 = .{ 0, 0, 0 };
    var param_idx: usize = 0;

    while (pos < buf.len) {
        const c = buf[pos];
        if (c == ';') {
            param_idx += 1;
            if (param_idx >= 3) break;
            pos += 1;
            continue;
        }
        if (c == 'M' or c == 'm') break;
        if (c >= '0' and c <= '9') {
            params[param_idx] = params[param_idx] * 10 + @as(u16, c - '0');
        }
        pos += 1;
    }

    const button = params[0];
    const cx = params[1];
    const cy = params[2];

    // Find the terminator
    var is_press = false;
    for (buf[3..]) |c| {
        if (c == 'M') {
            is_press = true;
            break;
        }
        if (c == 'm') break;
    }

    // Scroll wheel
    if (button == 64) return .scroll_up;
    if (button == 65) return .scroll_down;

    // Left click press
    if (button == 0 and is_press) {
        return .{ .mouse_click = .{
            .row = if (cy > 0) cy - 1 else 0,
            .col = if (cx > 0) cx - 1 else 0,
        } };
    }

    return .none;
}

// ── Output functions ──

fn writeStr(s: []const u8) void {
    for (s) |c| {
        if (write_pos >= WRITE_BUF_SIZE) {
            doFlush() catch {};
        }
        write_buf[write_pos] = c;
        write_pos += 1;
    }
}

/// Write raw bytes to the terminal output buffer.
pub fn write(bytes: []const u8) void {
    writeStr(bytes);
}

fn doFlush() !void {
    if (write_pos == 0) return;
    const stdout = std.fs.File.stdout();
    var written: usize = 0;
    while (written < write_pos) {
        written += try stdout.write(write_buf[written..write_pos]);
    }
    write_pos = 0;
}

/// Flush the terminal output buffer.
pub fn flush() !void {
    try doFlush();
}

fn writeFmt(comptime fmt: []const u8, args: anytype) void {
    var local_buf: [128]u8 = undefined;
    const slice = std.fmt.bufPrint(&local_buf, fmt, args) catch return;
    writeStr(slice);
}

/// Move the cursor to the specified row and column (0-indexed).
pub fn moveCursor(row: u16, col: u16) void {
    writeFmt("\x1b[{d};{d}H", .{ @as(u32, row) + 1, @as(u32, col) + 1 });
}

/// Set the foreground color.
pub fn setFg(color: Color) void {
    switch (color) {
        .default => writeStr("\x1b[39m"),
        .ansi => |c| writeFmt("\x1b[38;5;{d}m", .{c}),
        .rgb => |c| {
            if (truecolor_supported) {
                writeFmt("\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
            } else {
                writeFmt("\x1b[38;5;{d}m", .{rgbTo256(c.r, c.g, c.b)});
            }
        },
    }
}

/// Set the background color.
pub fn setBg(color: Color) void {
    switch (color) {
        .default => writeStr("\x1b[49m"),
        .ansi => |c| writeFmt("\x1b[48;5;{d}m", .{c}),
        .rgb => |c| {
            if (truecolor_supported) {
                writeFmt("\x1b[48;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
            } else {
                writeFmt("\x1b[48;5;{d}m", .{rgbTo256(c.r, c.g, c.b)});
            }
        },
    }
}

/// Set text attributes.
pub fn setAttr(bold: bool, dim: bool, underline: bool, reverse: bool) void {
    if (bold) writeStr("\x1b[1m");
    if (dim) writeStr("\x1b[2m");
    if (underline) writeStr("\x1b[4m");
    if (reverse) writeStr("\x1b[7m");
}

/// Reset all styles to terminal defaults.
pub fn resetStyle() void {
    writeStr("\x1b[0m");
}

/// Clear the entire screen.
pub fn clear() void {
    writeStr("\x1b[2J\x1b[H");
}

/// Hide the cursor.
pub fn hideCursor() void {
    writeStr("\x1b[?25l");
}

/// Show the cursor.
pub fn showCursor() void {
    writeStr("\x1b[?25h");
}

/// Set the cursor shape.
pub fn setCursorShape(shape: CursorShape) void {
    switch (shape) {
        .bar => writeStr("\x1b[6 q"),
        .block => writeStr("\x1b[2 q"),
        .underline => writeStr("\x1b[4 q"),
    }
}

/// Convert RGB to nearest xterm-256 color.
pub fn rgbTo256(r: u8, g: u8, b: u8) u8 {
    // Check grayscale
    if (r == g and g == b) {
        if (r < 8) return 16;
        if (r > 248) return 231;
        return @intCast(@as(u16, @intCast(r - 8)) * 24 / 247 + 232);
    }

    // Map to 6x6x6 cube
    const ri: u8 = @intCast(@as(u16, @intCast(r)) * 5 / 255);
    const gi: u8 = @intCast(@as(u16, @intCast(g)) * 5 / 255);
    const bi: u8 = @intCast(@as(u16, @intCast(b)) * 5 / 255);

    return 16 + 36 * ri + 6 * gi + bi;
}

// ── Tests ──

test "rgbTo256 known values" {
    try std.testing.expectEqual(@as(u8, 196), rgbTo256(255, 0, 0));
    try std.testing.expectEqual(@as(u8, 231), rgbTo256(255, 255, 255));
    try std.testing.expectEqual(@as(u8, 16), rgbTo256(0, 0, 0));
    const gray = rgbTo256(128, 128, 128);
    try std.testing.expect(gray >= 232 and gray <= 255);
}

test "escape sequence output" {
    write_pos = 0;
    moveCursor(0, 0);
    try std.testing.expectEqualSlices(u8, "\x1b[1;1H", write_buf[0..write_pos]);

    write_pos = 0;
    setFg(.{ .ansi = 196 });
    try std.testing.expectEqualSlices(u8, "\x1b[38;5;196m", write_buf[0..write_pos]);

    write_pos = 0;
    setBg(.default);
    try std.testing.expectEqualSlices(u8, "\x1b[49m", write_buf[0..write_pos]);
}

test "key parsing - arrows and special keys" {
    try std.testing.expectEqual(Key.up, parseEscape("\x1b[A"));
    try std.testing.expectEqual(Key.down, parseEscape("\x1b[B"));
    try std.testing.expectEqual(Key.right, parseEscape("\x1b[C"));
    try std.testing.expectEqual(Key.left, parseEscape("\x1b[D"));
    try std.testing.expectEqual(Key.home, parseEscape("\x1b[H"));
    try std.testing.expectEqual(Key.end, parseEscape("\x1b[F"));
    try std.testing.expectEqual(Key.delete, parseEscape("\x1b[3~"));
    try std.testing.expectEqual(Key.page_up, parseEscape("\x1b[5~"));
    try std.testing.expectEqual(Key.page_down, parseEscape("\x1b[6~"));
}

test "key parsing - SGR mouse scroll" {
    try std.testing.expectEqual(Key.scroll_up, parseEscape("\x1b[<64;1;1M"));
    try std.testing.expectEqual(Key.scroll_down, parseEscape("\x1b[<65;1;1M"));
}

test "key parsing - SGR mouse click" {
    const result = parseEscape("\x1b[<0;10;5M");
    switch (result) {
        .mouse_click => |pos| {
            try std.testing.expectEqual(@as(u16, 4), pos.row);
            try std.testing.expectEqual(@as(u16, 9), pos.col);
        },
        else => return error.TestUnexpectedResult,
    }
}
