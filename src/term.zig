//! Terminal I/O abstraction.
//!
//! Provides raw mode terminal input/output, key reading, cursor control,
//! color and style management, and screen operations over POSIX termios
//! (Linux, macOS, OpenBSD).

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const unicode = @import("unicode.zig");

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
    mouse_shift_click: struct { row: u16, col: u16 },
    mouse_drag: struct { row: u16, col: u16 },
    mouse_release: struct { row: u16, col: u16 },
    shift_up,
    shift_down,
    shift_left,
    shift_right,
    shift_home,
    shift_end,
    ctrl_word_left,
    ctrl_word_right,
    ctrl_shift_left,
    ctrl_shift_right,
    ctrl: u8,
    f1,
    help, // Ctrl+/ or Ctrl+Shift+?
    mouse_middle: struct { row: u16, col: u16 }, // middle button — primary-selection paste
    /// A block of already-decoded text from a bracketed paste (DECSET 2004,
    /// ESC[200~ … ESC[201~) — always the result of the user pasting. The
    /// slice points into a module-static buffer valid only until the next
    /// readKey call, so the caller must consume it before reading the next key.
    paste: []const u8,
    /// Decoded text from an OSC 52 clipboard-read reply (ESC]52;c|p;<base64>),
    /// which the terminal sends only in answer to a query we emitted. The
    /// caller should insert it only if it is still expecting a reply (a late
    /// reply after the fallback fired must be ignored). Same buffer-lifetime
    /// caveat as `.paste`.
    clipboard_reply: []const u8,
    paste_start, // internal: DECSET 2004 start marker (intercepted in readKeyPosix)
    paste_end, // internal: DECSET 2004 end marker (intercepted in readKeyPosix)
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

// ── Paste / OSC-52 capture ──
//
// A bracketed paste body and an OSC-52 clipboard reply are both delivered
// to the editor as a single `.paste` blob rather than streamed byte-by-byte
// through the key parser — that is what keeps a pasted newline from firing
// an Enter command, a pasted control byte from switching modes, and an ESC
// inside pasted text from being mis-parsed as an escape sequence.
//
// `paste_buf` holds one chunk of decoded paste text. A paste larger than
// the buffer is delivered as several consecutive `.paste` events. It is
// module-static (not heap) so term stays allocation-free; the slice handed
// to the editor is only valid until the next readKey call.
const PASTE_BUF_SIZE = 64 * 1024;
var paste_buf: [PASTE_BUF_SIZE]u8 = undefined;
// True while inside a bracketed paste body (between ESC[200~ and ESC[201~).
var paste_active: bool = false;

// Raw OSC payload accumulation buffer (the `52;c;<base64>` bytes). Sized to
// hold the base64 encoding of a PASTE_BUF_SIZE clipboard plus the short
// `52;c;` prefix. A reply larger than this is refused (returns .none).
const OSC_ACCUM_SIZE = 90 * 1024;
var osc_accum: [OSC_ACCUM_SIZE]u8 = undefined;

// How many empty ~100ms read windows to tolerate while waiting for the rest
// of a split escape sequence before giving up. Bounds the worst case for a
// slow link without stranding a lone Escape keypress.
const max_split_waits: usize = 3;

// How many empty ~100ms read windows to wait for the rest of a split
// bracketed-paste end marker (ESC[201~) mid-body. More generous than
// `max_split_waits` — we are certainly inside a paste and the terminator is
// certainly coming, so this only bounds a pathological broken stream (~2s).
const max_marker_waits: usize = 20;

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

        // Enable mouse button events + button-event drag tracking + SGR
        // extended mouse format. Mode 1002 is what makes drag motion
        // arrive at all — without it the terminal only reports clicks.
        writeStr("\x1b[?1000h\x1b[?1002h\x1b[?1006h");
        // Enable bracketed paste (DECSET 2004): the terminal wraps
        // pasted content in ESC[200~ … ESC[201~ so the editor can
        // suppress auto-indent etc. during the paste.
        writeStr("\x1b[?2004h");
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
        writeStr("\x1b[?1000l\x1b[?1002l\x1b[?1006l");
        // Disable bracketed paste
        writeStr("\x1b[?2004l");
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

/// Restore the terminal from a crash path (panic handler or fatal
/// signal). Writes the restore sequences with a direct blocking write —
/// bypassing the buffered writer, whose state may be arbitrary — and
/// restores the saved termios. Safe to call at any time; a no-op when
/// init() hasn't run.
pub fn emergencyRestore() void {
    if (!initialized) return;
    initialized = false;
    if (is_posix) {
        const seq = "\x1b[0 q" ++ // default cursor shape
            "\x1b[?1000l\x1b[?1002l\x1b[?1006l" ++ // mouse off
            "\x1b[?2004l" ++ // bracketed paste off
            "\x1b[?1049l" ++ // leave alternate screen
            "\x1b[0m" ++ // reset styles
            "\x1b[?25h"; // show cursor
        std.fs.File.stdout().writeAll(seq) catch {};
        const stdin_fd = std.fs.File.stdin().handle;
        posix.tcsetattr(stdin_fd, .FLUSH, orig_termios) catch {};
    }
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
    } else if (read_end == READ_BUF_SIZE and read_start > 0) {
        // Compact pending bytes to the front so an in-flight escape
        // sequence at the tail of the buffer has room to complete.
        const n = read_end - read_start;
        std.mem.copyForwards(u8, read_buf[0..n], read_buf[read_start..read_end]);
        read_start = 0;
        read_end = n;
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
    // Inside a bracketed paste body: keep handing the editor decoded text
    // chunks (never key events) until the ESC[201~ terminator is consumed.
    if (paste_active) return capturePasteBody();

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

    // Ctrl+/ (0x1f) = help overlay
    if (b == 0x1f) {
        readBufConsume(1);
        return .help;
    }

    // Other ctrl keys
    if (b < 0x20 and b != 0x1b) {
        readBufConsume(1);
        return .{ .ctrl = b + 'a' - 1 };
    }

    // Escape sequences
    if (b == 0x1b) {
        var split_waits: usize = 0;
        while (true) {
            const avail = readBufAvailable();

            // OSC: ESC ] … (BEL | ST). Used here to catch an OSC 52
            // clipboard-read reply and turn it into a `.paste` blob. Any
            // other OSC is consumed and ignored.
            if (avail >= 2 and readBufPeek(1) == ']') return captureOsc();

            if (parseEscape(readBufSlice(0, avail))) |r| {
                readBufConsume(r.len);
                switch (r.key) {
                    // Bracketed paste start: switch to body-capture mode and
                    // return the first decoded chunk. The editor never sees
                    // the raw markers.
                    .paste_start => {
                        paste_active = true;
                        return capturePasteBody();
                    },
                    // A stray end marker outside a paste (e.g. after a
                    // split-recovery) — skip it and read the next key.
                    .paste_end => return readKeyPosix(),
                    else => return r.key,
                }
            }
            // Valid-but-incomplete sequence (e.g. "ESC [" split across
            // reads over a slow connection). Try to pull more bytes —
            // fillReadBuf waits up to the 100ms termios timeout once.
            fillReadBuf();
            if (readBufAvailable() == avail) {
                // Nothing more arrived. Distinguish a lone Escape keypress
                // (buffer is exactly ESC — bail immediately) from a genuine
                // CSI/SS3 sequence straddling the timeout (ESC [ … / ESC O …
                // — keep waiting a bounded number of windows so a paste
                // marker split by a slow link isn't corrupted into literal
                // text).
                if (avail >= 2 and (readBufPeek(1) == '[' or readBufPeek(1) == 'O')) {
                    split_waits += 1;
                    if (split_waits < max_split_waits) continue;
                }
                readBufConsume(1);
                return .escape;
            }
            split_waits = 0; // progress made — reset patience
        }
    }

    // UTF-8 decode
    if (b < 0x80) {
        readBufConsume(1);
        return .{ .char = @intCast(b) };
    }

    // Multi-byte UTF-8. If the sequence is split across reads, try one
    // refill before decoding; unicode.decode validates continuation
    // bytes and rejects overlong/surrogate encodings, yielding U+FFFD
    // (len 1) for malformed input so we always make progress.
    const expected: usize = unicode.utf8Len(b);
    if (expected > readBufAvailable()) {
        fillReadBuf();
    }
    const take = @min(expected, readBufAvailable());
    const r = unicode.decode(readBufSlice(0, take));
    readBufConsume(r.len);
    return .{ .char = r.codepoint };
}

const EscParse = struct { key: Key, len: usize };

/// Maximum CSI parameter bytes before we declare the sequence malformed
/// and flush it, rather than waiting forever for a terminator.
const max_csi_len = 32;

/// Parse one escape sequence from the front of `buf` (buf[0] must be ESC).
/// Returns the decoded key plus the number of bytes consumed, or null when
/// the bytes so far form a valid but incomplete sequence — the caller
/// should read more input and retry. A bare ESC followed by a byte that
/// doesn't start a known sequence is returned as .escape consuming only
/// the ESC, so the following character is not swallowed.
fn parseEscape(buf: []const u8) ?EscParse {
    if (buf.len < 2) return null;

    // SS3 sequences: ESC O <final> (F1-F4, and home/end as sent by
    // macOS Terminal.app — nsterm terminfo has khome=\eOH, kend=\eOF —
    // and by xterm-family terminals in application cursor mode).
    if (buf[1] == 'O') {
        if (buf.len < 3) return null;
        const key: Key = switch (buf[2]) {
            'P' => .f1,
            'H' => .home,
            'F' => .end,
            else => .unknown,
        };
        return .{ .key = key, .len = 3 };
    }

    if (buf[1] != '[') {
        // Not CSI/SS3 — standalone ESC; don't eat the following byte.
        return .{ .key = .escape, .len = 1 };
    }

    // CSI: ESC [ <params/intermediates> <final 0x40..0x7E>. '[' is
    // excluded as a terminator so linux-console "ESC [ [ A" F-keys
    // don't truncate early.
    var i: usize = 2;
    while (i < buf.len) : (i += 1) {
        const c = buf[i];
        if (c >= 0x40 and c <= 0x7E and c != '[') {
            return .{ .key = parseCsi(buf[0 .. i + 1]), .len = i + 1 };
        }
        if (i >= max_csi_len) {
            // Runaway parameter bytes — malformed; flush what we have.
            return .{ .key = .unknown, .len = i + 1 };
        }
    }
    return null; // incomplete — no terminator yet
}

/// Decode a complete CSI sequence (ESC [ ... final).
fn parseCsi(buf: []const u8) Key {
    if (buf.len < 3) return .unknown;

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

    // ESC [ 200 ~ / 201 ~ = bracketed paste start/end (DECSET 2004).
    if (buf.len >= 6 and buf[2] == '2' and buf[3] == '0' and buf[5] == '~') {
        return switch (buf[4]) {
            '0' => .paste_start,
            '1' => .paste_end,
            else => .unknown,
        };
    }

    // ESC [ 3 ~ = delete
    if (buf[2] == '3' and buf[3] == '~') return .delete;

    // ESC [ 1 1 ~ = F1
    if (buf[2] == '1' and buf.len >= 5 and buf[3] == '1' and buf[4] == '~') return .f1;

    // ESC [ 1 ; 5 C/D = ctrl+right/left. Emit distinct word-jump
    // keys so handleCtrl's 'f' (search) doesn't swallow a ctrl+right
    // intended for word navigation.
    if (buf[2] == '1' and buf.len >= 6 and buf[3] == ';' and buf[4] == '5') {
        return switch (buf[5]) {
            'C' => .ctrl_word_right,
            'D' => .ctrl_word_left,
            else => .unknown,
        };
    }

    // ESC [ 1 ; 2 X = shift+arrow / shift+home / shift+end. Modifier
    // code 2 is the standard xterm shift modifier; we use these to
    // start and extend a keyboard-driven selection.
    if (buf[2] == '1' and buf.len >= 6 and buf[3] == ';' and buf[4] == '2') {
        return switch (buf[5]) {
            'A' => .shift_up,
            'B' => .shift_down,
            'C' => .shift_right,
            'D' => .shift_left,
            'H' => .shift_home,
            'F' => .shift_end,
            else => .unknown,
        };
    }

    // ESC [ 1 ; 6 C/D = ctrl+shift+right/left (xterm modifier 6 =
    // ctrl+shift). Used for word-wise selection extension.
    if (buf[2] == '1' and buf.len >= 6 and buf[3] == ';' and buf[4] == '6') {
        return switch (buf[5]) {
            'C' => .ctrl_shift_right,
            'D' => .ctrl_shift_left,
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
            // Saturating accumulation: a hostile or pasted sequence like
            // ESC[<70000;1;1M would otherwise overflow u16 and, in a
            // ReleaseSafe build, abort the process. Clamp instead —
            // coordinates past the terminal size are meaningless anyway.
            const next = @as(u32, params[param_idx]) * 10 + (c - '0');
            params[param_idx] = if (next > std.math.maxInt(u16))
                std.math.maxInt(u16)
            else
                @intCast(next);
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

    // Scroll wheel. SGR encodes modifiers on the button value
    // (shift=4, meta=8, ctrl=16), so shift+scroll arrives as 68/69 and
    // ctrl+scroll as 80/81. Strip the modifier bits — a modified scroll
    // should still scroll rather than being silently dropped. Values
    // 96+ carry the motion bit (32) and are wheel-drag noise.
    if (button >= 64 and button < 96) {
        return if (button & 1 == 0) .scroll_up else .scroll_down;
    }

    const row: u16 = if (cy > 0) cy - 1 else 0;
    const col: u16 = if (cx > 0) cx - 1 else 0;

    // Left click press / release
    if (button == 0) {
        if (is_press) {
            return .{ .mouse_click = .{ .row = row, .col = col } };
        } else {
            return .{ .mouse_release = .{ .row = row, .col = col } };
        }
    }

    // Middle button (SGR button 1). With mouse reporting enabled the
    // terminal forwards the middle click to us instead of doing its own
    // primary-selection paste, so we react on press by pasting the primary
    // selection ourselves (via an OSC 52 read). Release is a no-op.
    if (button == 1) {
        if (is_press) {
            return .{ .mouse_middle = .{ .row = row, .col = col } };
        }
        return .none;
    }

    // SGR encodes modifier bits on the button: shift=4, meta=8,
    // ctrl=16. Left-click with shift held is button 0 | 4 = 4. Emit
    // a distinct key so the editor can extend the existing selection
    // anchor instead of starting a new click.
    if (button == 4) {
        if (is_press) {
            return .{ .mouse_shift_click = .{ .row = row, .col = col } };
        } else {
            return .{ .mouse_release = .{ .row = row, .col = col } };
        }
    }

    // Mode 1002 reports left-button drag motion as button 32. Buttons
    // 33/34 (middle/right drag) are intentionally ignored. Button 36
    // is a shift-held drag (32 | 4); treat it the same as a plain
    // drag so selection extension works after a shift+click.
    if (button == 32 or button == 36) {
        return .{ .mouse_drag = .{ .row = row, .col = col } };
    }

    return .none;
}

// ── Paste / OSC-52 capture ──

/// True when the 6 bytes are the bracketed-paste end marker ESC[201~.
fn isPasteEnd(s: []const u8) bool {
    return s.len >= 6 and s[0] == 0x1b and s[1] == '[' and
        s[2] == '2' and s[3] == '0' and s[4] == '1' and s[5] == '~';
}

/// True when `s` is a (possibly partial) leading prefix of ESC[201~.
fn isPasteEndPrefix(s: []const u8) bool {
    const marker = "\x1b[201~";
    if (s.len == 0 or s.len >= marker.len) return false;
    return std.mem.eql(u8, s, marker[0..s.len]);
}

/// Capture the body of a bracketed paste into `paste_buf` and return it as a
/// single `.paste` event. Called repeatedly while `paste_active`: a body
/// larger than the buffer comes back as several consecutive `.paste` chunks,
/// and `paste_active` is cleared once the ESC[201~ terminator is consumed.
///
/// ESC bytes inside the pasted text are captured literally (the terminal only
/// filters the terminator, not other control bytes), and the terminator may
/// arrive split across reads — both handled without ever tokenizing the
/// content as key events.
fn capturePasteBody() Key {
    var n: usize = 0;
    var waits: usize = 0;
    while (n < PASTE_BUF_SIZE) {
        if (readBufAvailable() == 0) {
            fillReadBuf();
            if (readBufAvailable() == 0) {
                if (n > 0) break; // hand over what we have; resume next call
                waits += 1;
                if (waits >= max_split_waits) {
                    // The stream stalled with nothing captured. Give up on
                    // the paste rather than hang forever; the terminal
                    // normally sends ESC[201~ promptly.
                    paste_active = false;
                    return .none;
                }
                continue;
            }
        }
        const c = readBufPeek(0);
        if (c == 0x1b) {
            // Resolve, inline, whether this ESC begins the ESC[201~ terminator
            // or is a literal ESC in the pasted text. A bracketed paste always
            // ends with this terminator, so when the marker is split across
            // reads we wait (bounded) for the rest — `isPasteEndPrefix` keeps
            // us waiting only while the bytes still match the marker, so a
            // literal ESC in content (which diverges) stops the wait at once.
            // Resolving here rather than returning partial content keeps a
            // slow-link split from ever stranding `paste_active`.
            var marker_waits: usize = 0;
            while (readBufAvailable() < 6 and
                isPasteEndPrefix(readBufSlice(0, readBufAvailable())))
            {
                const before = readBufAvailable();
                fillReadBuf();
                if (readBufAvailable() == before) {
                    marker_waits += 1;
                    if (marker_waits >= max_marker_waits) break;
                }
            }
            if (readBufAvailable() >= 6 and isPasteEnd(readBufSlice(0, 6))) {
                readBufConsume(6);
                paste_active = false;
                break;
            }
            // Not the terminator — capture the ESC as literal content.
            paste_buf[n] = c;
            n += 1;
            readBufConsume(1);
            waits = 0;
            continue;
        }
        paste_buf[n] = c;
        n += 1;
        readBufConsume(1);
        waits = 0;
    }
    return .{ .paste = paste_buf[0..n] };
}

/// Consume an OSC sequence beginning at ESC ] and, if it is an OSC 52
/// clipboard reply (`ESC ] 52 ; <sel> ; <base64> BEL|ST`), base64-decode the
/// payload into `paste_buf` and return it as a `.paste` event. Any other OSC,
/// a malformed reply, or an oversize payload returns `.none`.
fn captureOsc() Key {
    // Consume the leading ESC ].
    readBufConsume(2);

    var n: usize = 0;
    var waits: usize = 0;
    while (true) {
        if (readBufAvailable() == 0) {
            fillReadBuf();
            if (readBufAvailable() == 0) {
                waits += 1;
                if (waits >= max_split_waits) return .none; // stalled
                continue;
            }
            waits = 0;
        }
        const c = readBufPeek(0);
        if (c == 0x07) { // BEL terminator
            readBufConsume(1);
            break;
        }
        if (c == 0x1b) { // possible ST terminator (ESC \)
            if (readBufAvailable() < 2) {
                fillReadBuf();
                if (readBufAvailable() < 2) {
                    waits += 1;
                    if (waits >= max_split_waits) return .none;
                    continue;
                }
            }
            if (readBufPeek(1) == '\\') {
                readBufConsume(2);
                break;
            }
            // A bare ESC mid-OSC — malformed; stop here.
            readBufConsume(1);
            break;
        }
        if (n >= OSC_ACCUM_SIZE) return .none; // oversize — refuse
        osc_accum[n] = c;
        n += 1;
        readBufConsume(1);
    }

    return decodeOsc52(osc_accum[0..n]);
}

/// Given the raw payload of an OSC (everything between `ESC ]` and the
/// terminator), decode an OSC 52 clipboard reply into a `.paste` event.
fn decodeOsc52(payload: []const u8) Key {
    // Expect: 52 ; <selector> ; <base64>
    if (!std.mem.startsWith(u8, payload, "52;")) return .none;
    const after_kind = payload[3..];
    const semi = std.mem.indexOfScalar(u8, after_kind, ';') orelse return .none;
    const b64 = after_kind[semi + 1 ..];
    if (b64.len == 0) return .none;

    const decoder = std.base64.standard.Decoder;
    const decoded_len = decoder.calcSizeForSlice(b64) catch return .none;
    if (decoded_len == 0 or decoded_len > PASTE_BUF_SIZE) return .none;
    decoder.decode(paste_buf[0..decoded_len], b64) catch return .none;
    return .{ .clipboard_reply = paste_buf[0..decoded_len] };
}

// ── Output functions ──

fn writeStr(s: []const u8) void {
    for (s) |c| {
        if (write_pos >= WRITE_BUF_SIZE) {
            // Flush to make room. If the flush fails (e.g. the pty/
            // terminal was torn down and write() returns EPIPE),
            // write_pos stays at capacity — drop the byte rather than
            // storing one past the end of the buffer, which would panic
            // in ReleaseSafe or corrupt memory otherwise.
            doFlush() catch {};
            if (write_pos >= WRITE_BUF_SIZE) return;
        }
        write_buf[write_pos] = c;
        write_pos += 1;
    }
}

/// Write raw bytes to the terminal output buffer.
pub fn write(bytes: []const u8) void {
    writeStr(bytes);
}

/// Maximum raw bytes accepted for the system clipboard via OSC 52. Most
/// terminals drop longer sequences anyway (xterm's default is much
/// smaller). Data over the cap is refused outright — silently sending
/// a truncated clipboard would be worse than not sending one.
pub const osc52_max_bytes: usize = 100 * 1024;

/// Emit an OSC 52 sequence pushing `data` onto the terminal's system
/// clipboard. Base64-encodes `data` in-place via the output buffer —
/// no heap allocation. No-op if the terminal isn't initialized,
/// `data` is empty, or `data` exceeds `osc52_max_bytes`.
/// The internal editor clipboard is unaffected either way.
pub fn writeOsc52Clipboard(data: []const u8) void {
    if (!initialized) return;
    if (data.len == 0 or data.len > osc52_max_bytes) return;

    const capped = data;

    writeStr("\x1b]52;c;");

    // Encode in 3-byte chunks so no padding appears mid-stream. The
    // tail (0, 1, or 2 bytes) is encoded separately with padding.
    const chunk_in: usize = 768; // multiple of 3 -> no padding
    const chunk_out: usize = 1024;
    var out_buf: [chunk_out]u8 = undefined;
    const encoder = std.base64.standard.Encoder;

    var i: usize = 0;
    while (i + chunk_in <= capped.len) : (i += chunk_in) {
        _ = encoder.encode(&out_buf, capped[i..][0..chunk_in]);
        writeStr(&out_buf);
    }
    const rem = capped.len - i;
    if (rem > 0) {
        const enc_len = encoder.calcSize(rem);
        _ = encoder.encode(out_buf[0..enc_len], capped[i..][0..rem]);
        writeStr(out_buf[0..enc_len]);
    }

    writeStr("\x07");
}

/// Emit an OSC 52 clipboard *read* query. The terminal replies on stdin with
/// `ESC ] 52 ; <sel> ; <base64> BEL`, which readKeyPosix turns into a `.paste`
/// event. `primary` selects the primary selection (selector `p`, what
/// middle-click pastes) instead of the clipboard (selector `c`). No-op if the
/// terminal isn't initialized; the reply may never come if the terminal has
/// OSC 52 read disabled, so callers must arrange a fallback.
pub fn requestOsc52Read(primary: bool) void {
    if (!initialized) return;
    writeStr(if (primary) "\x1b]52;p;?\x07" else "\x1b]52;c;?\x07");
    doFlush() catch {};
}

/// After requestOsc52Read, block up to `timeout_ms` for the terminal's reply
/// and return its decoded text (into `paste_buf`), or null on timeout / if the
/// terminal has OSC 52 read disabled (no reply). A local terminal answers in
/// well under a millisecond, so the common path returns almost immediately;
/// the timeout only bites on terminals that never answer.
///
/// Consumes only the reply itself — if the next input is an ordinary keypress
/// (the user typed in the sub-millisecond window), it is left in the buffer
/// for readKey, and we report timeout so the caller falls back to the internal
/// clipboard rather than swallowing the keystroke.
pub fn readOsc52Reply(timeout_ms: i64) ?[]const u8 {
    if (!initialized) return null;
    const start = std.time.milliTimestamp();
    while (std.time.milliTimestamp() - start < timeout_ms) {
        if (readBufAvailable() == 0) {
            fillReadBuf(); // returns on the first byte, or after ~100ms
            if (readBufAvailable() == 0) continue;
        }
        if (readBufPeek(0) != 0x1b) return null; // an ordinary key — leave it
        if (readBufAvailable() < 2) {
            fillReadBuf();
            if (readBufAvailable() < 2) return null;
        }
        if (readBufPeek(1) != ']') return null; // some other escape — leave it
        return switch (captureOsc()) {
            .clipboard_reply => |t| t,
            else => null, // a non-clipboard OSC or malformed reply
        };
    }
    return null;
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

test "OSC 52 clipboard emits nothing when terminal is not initialized" {
    // Tests don't call init(), so the function is a safe no-op.
    write_pos = 0;
    writeOsc52Clipboard("hello");
    try std.testing.expectEqual(@as(usize, 0), write_pos);
}

test "OSC 52 clipboard base64-encodes under a forced init" {
    const save = initialized;
    initialized = true;
    defer initialized = save;

    write_pos = 0;
    writeOsc52Clipboard("Man");
    // "Man" base64 = "TWFu" (3 bytes -> 4 bytes, no padding).
    try std.testing.expectEqualSlices(u8, "\x1b]52;c;TWFu\x07", write_buf[0..write_pos]);

    write_pos = 0;
    writeOsc52Clipboard("M");
    // "M" base64 = "TQ==" (1 byte -> 4 bytes with padding).
    try std.testing.expectEqualSlices(u8, "\x1b]52;c;TQ==\x07", write_buf[0..write_pos]);

    write_pos = 0;
    writeOsc52Clipboard("");
    try std.testing.expectEqual(@as(usize, 0), write_pos);
}

test "OSC 52 clipboard handles chunk boundary" {
    const save = initialized;
    initialized = true;
    defer initialized = save;

    // 768 is the chunk_in size used internally; encode exactly one
    // chunk plus a two-byte tail so both code paths fire.
    var big: [770]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @intCast('a' + (i % 26));

    write_pos = 0;
    writeOsc52Clipboard(&big);

    // We just care that it produced an OSC 52 wrapper with >0 payload.
    try std.testing.expect(write_pos > 10);
    try std.testing.expectEqualSlices(u8, "\x1b]52;c;", write_buf[0..7]);
    try std.testing.expectEqual(@as(u8, 0x07), write_buf[write_pos - 1]);
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

fn parseKey(seq: []const u8) Key {
    const r = parseEscape(seq) orelse return .none;
    return r.key;
}

test "key parsing - arrows and special keys" {
    try std.testing.expectEqual(Key.up, parseKey("\x1b[A"));
    try std.testing.expectEqual(Key.down, parseKey("\x1b[B"));
    try std.testing.expectEqual(Key.right, parseKey("\x1b[C"));
    try std.testing.expectEqual(Key.left, parseKey("\x1b[D"));
    try std.testing.expectEqual(Key.home, parseKey("\x1b[H"));
    try std.testing.expectEqual(Key.end, parseKey("\x1b[F"));
    try std.testing.expectEqual(Key.home, parseKey("\x1b[1~"));
    try std.testing.expectEqual(Key.end, parseKey("\x1b[4~"));
    // macOS Terminal.app sends home/end as SS3 (nsterm khome/kend).
    try std.testing.expectEqual(Key.home, parseKey("\x1bOH"));
    try std.testing.expectEqual(Key.end, parseKey("\x1bOF"));
    try std.testing.expectEqual(Key.delete, parseKey("\x1b[3~"));
    try std.testing.expectEqual(Key.page_up, parseKey("\x1b[5~"));
    try std.testing.expectEqual(Key.page_down, parseKey("\x1b[6~"));
}

test "key parsing - incomplete sequences signal for more input" {
    // A CSI with no terminator yet must return null (read more), not a
    // bare escape — this is the split-read-over-SSH case.
    try std.testing.expectEqual(@as(?EscParse, null), parseEscape("\x1b"));
    try std.testing.expectEqual(@as(?EscParse, null), parseEscape("\x1b["));
    try std.testing.expectEqual(@as(?EscParse, null), parseEscape("\x1b[1;2"));
    try std.testing.expectEqual(@as(?EscParse, null), parseEscape("\x1bO"));

    // Once the terminator arrives the whole sequence parses.
    const r = parseEscape("\x1b[1;2C").?;
    try std.testing.expectEqual(Key.shift_right, r.key);
    try std.testing.expectEqual(@as(usize, 6), r.len);
}

test "key parsing - bare ESC before a plain char consumes only ESC" {
    const r = parseEscape("\x1bx").?;
    try std.testing.expectEqual(Key.escape, r.key);
    try std.testing.expectEqual(@as(usize, 1), r.len);
}

test "key parsing - runaway CSI is flushed as unknown" {
    const seq = "\x1b[" ++ "1;" ** 30;
    const r = parseEscape(seq).?;
    try std.testing.expectEqual(Key.unknown, r.key);
    try std.testing.expect(r.len > 2);
}

test "key parsing - SGR mouse scroll" {
    try std.testing.expectEqual(Key.scroll_up, parseKey("\x1b[<64;1;1M"));
    try std.testing.expectEqual(Key.scroll_down, parseKey("\x1b[<65;1;1M"));
    // Modified scroll (shift=+4, ctrl=+16) still scrolls.
    try std.testing.expectEqual(Key.scroll_up, parseKey("\x1b[<68;1;1M"));
    try std.testing.expectEqual(Key.scroll_down, parseKey("\x1b[<69;1;1M"));
    try std.testing.expectEqual(Key.scroll_up, parseKey("\x1b[<80;1;1M"));
    try std.testing.expectEqual(Key.scroll_down, parseKey("\x1b[<81;1;1M"));
}

test "key parsing - hostile SGR params saturate instead of overflowing u16" {
    // ESC[<70000;99999;88888M would overflow the u16 param accumulator
    // and abort a ReleaseSafe build. It must parse without panicking;
    // the scroll/click decode from the (clamped) button just yields a
    // benign event.
    const r = parseKey("\x1b[<70000;99999;88888M");
    switch (r) {
        .mouse_click, .mouse_drag, .scroll_up, .scroll_down, .none, .mouse_release => {},
        else => return error.TestUnexpectedResult,
    }
    // A wheel event with a huge coordinate still decodes as a scroll.
    try std.testing.expectEqual(Key.scroll_up, parseKey("\x1b[<64;99999;99999M"));
}

test "key parsing - SGR mouse click" {
    const result = parseKey("\x1b[<0;10;5M");
    switch (result) {
        .mouse_click => |pos| {
            try std.testing.expectEqual(@as(u16, 4), pos.row);
            try std.testing.expectEqual(@as(u16, 9), pos.col);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "key parsing - shift+arrow keys" {
    try std.testing.expectEqual(Key.shift_up, parseKey("\x1b[1;2A"));
    try std.testing.expectEqual(Key.shift_down, parseKey("\x1b[1;2B"));
    try std.testing.expectEqual(Key.shift_right, parseKey("\x1b[1;2C"));
    try std.testing.expectEqual(Key.shift_left, parseKey("\x1b[1;2D"));
    try std.testing.expectEqual(Key.shift_home, parseKey("\x1b[1;2H"));
    try std.testing.expectEqual(Key.shift_end, parseKey("\x1b[1;2F"));
}

test "key parsing - SGR mouse drag" {
    const result = parseKey("\x1b[<32;15;7M");
    switch (result) {
        .mouse_drag => |pos| {
            try std.testing.expectEqual(@as(u16, 6), pos.row);
            try std.testing.expectEqual(@as(u16, 14), pos.col);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "key parsing - SGR mouse release" {
    const result = parseKey("\x1b[<0;10;5m");
    switch (result) {
        .mouse_release => |pos| {
            try std.testing.expectEqual(@as(u16, 4), pos.row);
            try std.testing.expectEqual(@as(u16, 9), pos.col);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "key parsing - SGR middle-click emits mouse_middle on press only" {
    switch (parseKey("\x1b[<1;3;1M")) {
        .mouse_middle => |pos| {
            try std.testing.expectEqual(@as(u16, 0), pos.row);
            try std.testing.expectEqual(@as(u16, 2), pos.col);
        },
        else => return error.TestUnexpectedResult,
    }
    // Release (lowercase m) is a no-op.
    try std.testing.expectEqual(Key.none, parseKey("\x1b[<1;3;1m"));
}

test "bracketed paste end-marker detection" {
    try std.testing.expect(isPasteEnd("\x1b[201~"));
    try std.testing.expect(isPasteEnd("\x1b[201~trailing")); // only first 6 matter
    try std.testing.expect(!isPasteEnd("\x1b[200~")); // start marker, not end
    try std.testing.expect(!isPasteEnd("\x1b[201"));

    // Prefix predicate: a partial leading match keeps the reader waiting;
    // a full or diverging sequence stops it.
    try std.testing.expect(isPasteEndPrefix("\x1b"));
    try std.testing.expect(isPasteEndPrefix("\x1b[2"));
    try std.testing.expect(isPasteEndPrefix("\x1b[201"));
    try std.testing.expect(!isPasteEndPrefix("\x1b[201~")); // complete, not a prefix
    try std.testing.expect(!isPasteEndPrefix("\x1b[3")); // diverges
    try std.testing.expect(!isPasteEndPrefix("")); // empty
}

test "OSC 52 reply decoding" {
    // "hello" base64-encodes to "aGVsbG8=".
    switch (decodeOsc52("52;c;aGVsbG8=")) {
        .clipboard_reply => |t| try std.testing.expectEqualStrings("hello", t),
        else => return error.TestUnexpectedResult,
    }
    // Primary-selection selector also decodes.
    switch (decodeOsc52("52;p;aGVsbG8=")) {
        .clipboard_reply => |t| try std.testing.expectEqualStrings("hello", t),
        else => return error.TestUnexpectedResult,
    }
    // Non-clipboard OSC, empty payload, and malformed base64 are ignored.
    try std.testing.expectEqual(Key.none, decodeOsc52("0;some title"));
    try std.testing.expectEqual(Key.none, decodeOsc52("52;c;"));
    try std.testing.expectEqual(Key.none, decodeOsc52("52;c;!!!not-base64"));
}
