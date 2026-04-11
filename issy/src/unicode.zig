//! Unicode UTF-8 encoding and decoding utilities.
//!
//! Provides low-level functions for working with UTF-8 encoded text:
//! decoding codepoints, encoding codepoints, measuring byte lengths,
//! counting codepoints in a string, and validating UTF-8 sequences.

const std = @import("std");

/// Result of decoding a single UTF-8 codepoint.
pub const DecodeResult = struct {
    codepoint: u21,
    len: u3,
};

const replacement: u21 = 0xFFFD;

/// Decode the first UTF-8 codepoint from the given byte slice.
/// On malformed input, returns U+FFFD with len 1.
pub fn decode(bytes: []const u8) DecodeResult {
    if (bytes.len == 0) return .{ .codepoint = replacement, .len = 1 };

    const b0 = bytes[0];

    // ASCII fast path.
    if (b0 < 0x80) return .{ .codepoint = b0, .len = 1 };

    // Continuation or invalid leading byte.
    if (b0 < 0xC2) return .{ .codepoint = replacement, .len = 1 };

    const expected: u3 = utf8Len(b0);
    if (expected == 1) return .{ .codepoint = replacement, .len = 1 };
    if (bytes.len < expected) return .{ .codepoint = replacement, .len = 1 };

    // Validate all continuation bytes.
    for (1..expected) |i| {
        if (!isContByte(bytes[i])) return .{ .codepoint = replacement, .len = 1 };
    }

    var cp: u21 = undefined;
    switch (expected) {
        2 => {
            cp = @as(u21, b0 & 0x1F) << 6 |
                @as(u21, bytes[1] & 0x3F);
        },
        3 => {
            cp = @as(u21, b0 & 0x0F) << 12 |
                @as(u21, bytes[1] & 0x3F) << 6 |
                @as(u21, bytes[2] & 0x3F);
            // Reject overlong and surrogate halves.
            if (cp < 0x800 or (cp >= 0xD800 and cp <= 0xDFFF))
                return .{ .codepoint = replacement, .len = 1 };
        },
        4 => {
            cp = @as(u21, b0 & 0x07) << 18 |
                @as(u21, bytes[1] & 0x3F) << 12 |
                @as(u21, bytes[2] & 0x3F) << 6 |
                @as(u21, bytes[3] & 0x3F);
            // Reject overlong and out-of-range.
            if (cp < 0x10000 or cp > 0x10FFFF)
                return .{ .codepoint = replacement, .len = 1 };
        },
        else => return .{ .codepoint = replacement, .len = 1 },
    }

    return .{ .codepoint = cp, .len = expected };
}

/// Encode a Unicode codepoint as UTF-8 into the provided buffer.
/// Returns the number of bytes written (1-4).
pub fn encode(codepoint: u21, buf: *[4]u8) u3 {
    if (codepoint < 0x80) {
        buf[0] = @intCast(codepoint);
        return 1;
    } else if (codepoint < 0x800) {
        buf[0] = @intCast(0xC0 | (codepoint >> 6));
        buf[1] = @intCast(0x80 | (codepoint & 0x3F));
        return 2;
    } else if (codepoint < 0x10000) {
        buf[0] = @intCast(0xE0 | (codepoint >> 12));
        buf[1] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buf[2] = @intCast(0x80 | (codepoint & 0x3F));
        return 3;
    } else {
        buf[0] = @intCast(0xF0 | (codepoint >> 18));
        buf[1] = @intCast(0x80 | ((codepoint >> 12) & 0x3F));
        buf[2] = @intCast(0x80 | ((codepoint >> 6) & 0x3F));
        buf[3] = @intCast(0x80 | (codepoint & 0x3F));
        return 4;
    }
}

/// Return the expected byte length of a UTF-8 sequence given its first byte.
/// Returns 1 for invalid leading bytes.
pub fn utf8Len(first_byte: u8) u3 {
    if (first_byte < 0x80) return 1;
    if (first_byte < 0xC2) return 1; // continuation or overlong 2-byte
    if (first_byte < 0xE0) return 2;
    if (first_byte < 0xF0) return 3;
    if (first_byte < 0xF5) return 4;
    return 1; // 0xF5..0xFF invalid
}

/// Count the number of Unicode codepoints in a UTF-8 encoded slice.
pub fn countCodepoints(bytes: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const r = decode(bytes[i..]);
        i += r.len;
        count += 1;
    }
    return count;
}

/// Return the byte offset of the nth codepoint (0-indexed).
/// Returns null if n is beyond the number of codepoints.
pub fn nthCodepointOffset(bytes: []const u8, n: usize) ?usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < bytes.len) {
        if (count == n) return i;
        const r = decode(bytes[i..]);
        i += r.len;
        count += 1;
    }
    // n == count means one-past-end (valid for slicing).
    if (count == n) return i;
    return null;
}

/// Validate that the given byte slice is well-formed UTF-8.
pub fn validate(bytes: []const u8) bool {
    var i: usize = 0;
    while (i < bytes.len) {
        const r = decode(bytes[i..]);
        if (r.codepoint == replacement and !(bytes[i] == 0xEF and r.len == 3)) {
            // Got replacement char — only valid if the source bytes actually encode U+FFFD.
            return false;
        }
        i += r.len;
    }
    return true;
}

/// True if the byte is a UTF-8 continuation byte (0x80..0xBF).
pub fn isContByte(b: u8) bool {
    return b & 0xC0 == 0x80;
}

// ──────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────

test "decode ASCII" {
    const r = decode("A");
    try std.testing.expectEqual(@as(u21, 'A'), r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode null byte" {
    const r = decode(&[_]u8{0x00});
    try std.testing.expectEqual(@as(u21, 0), r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode 2-byte: e-acute U+00E9" {
    const r = decode("\xC3\xA9");
    try std.testing.expectEqual(@as(u21, 0x00E9), r.codepoint);
    try std.testing.expectEqual(@as(u3, 2), r.len);
}

test "decode 2-byte: n-tilde U+00F1" {
    const r = decode("\xC3\xB1");
    try std.testing.expectEqual(@as(u21, 0x00F1), r.codepoint);
    try std.testing.expectEqual(@as(u3, 2), r.len);
}

test "decode 3-byte: CJK U+4E16 (世)" {
    const r = decode("\xE4\xB8\x96");
    try std.testing.expectEqual(@as(u21, 0x4E16), r.codepoint);
    try std.testing.expectEqual(@as(u3, 3), r.len);
}

test "decode 3-byte: Euro sign U+20AC" {
    const r = decode("\xE2\x82\xAC");
    try std.testing.expectEqual(@as(u21, 0x20AC), r.codepoint);
    try std.testing.expectEqual(@as(u3, 3), r.len);
}

test "decode 4-byte: musical symbol G clef U+1D11E" {
    const r = decode("\xF0\x9D\x84\x9E");
    try std.testing.expectEqual(@as(u21, 0x1D11E), r.codepoint);
    try std.testing.expectEqual(@as(u3, 4), r.len);
}

test "decode 4-byte: grinning face emoji U+1F600" {
    const r = decode("\xF0\x9F\x98\x80");
    try std.testing.expectEqual(@as(u21, 0x1F600), r.codepoint);
    try std.testing.expectEqual(@as(u3, 4), r.len);
}

test "decode empty slice" {
    const r = decode("");
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode overlong 2-byte sequence (U+002F encoded as C0 AF)" {
    const r = decode("\xC0\xAF");
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode overlong 3-byte sequence (U+007F encoded as E0 81 BF)" {
    const r = decode("\xE0\x81\xBF");
    try std.testing.expectEqual(replacement, r.codepoint);
}

test "decode truncated 2-byte sequence" {
    const r = decode("\xC3");
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode truncated 3-byte sequence" {
    const r = decode("\xE4\xB8");
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode truncated 4-byte sequence" {
    const r = decode("\xF0\x9F\x98");
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode invalid byte 0xFF" {
    const r = decode(&[_]u8{0xFF});
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode invalid byte 0xFE" {
    const r = decode(&[_]u8{0xFE});
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode lone continuation byte" {
    const r = decode(&[_]u8{0x80});
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode lone continuation byte 0xBF" {
    const r = decode(&[_]u8{0xBF});
    try std.testing.expectEqual(replacement, r.codepoint);
    try std.testing.expectEqual(@as(u3, 1), r.len);
}

test "decode surrogate half U+D800" {
    // ED A0 80 = U+D800 (invalid)
    const r = decode("\xED\xA0\x80");
    try std.testing.expectEqual(replacement, r.codepoint);
}

test "encode ASCII" {
    var buf: [4]u8 = undefined;
    const len = encode('A', &buf);
    try std.testing.expectEqual(@as(u3, 1), len);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
}

test "encode null" {
    var buf: [4]u8 = undefined;
    const len = encode(0, &buf);
    try std.testing.expectEqual(@as(u3, 1), len);
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
}

test "encode 2-byte: e-acute" {
    var buf: [4]u8 = undefined;
    const len = encode(0x00E9, &buf);
    try std.testing.expectEqual(@as(u3, 2), len);
    try std.testing.expectEqualSlices(u8, "\xC3\xA9", buf[0..len]);
}

test "encode 3-byte: Euro sign" {
    var buf: [4]u8 = undefined;
    const len = encode(0x20AC, &buf);
    try std.testing.expectEqual(@as(u3, 3), len);
    try std.testing.expectEqualSlices(u8, "\xE2\x82\xAC", buf[0..len]);
}

test "encode 4-byte: emoji U+1F600" {
    var buf: [4]u8 = undefined;
    const len = encode(0x1F600, &buf);
    try std.testing.expectEqual(@as(u3, 4), len);
    try std.testing.expectEqualSlices(u8, "\xF0\x9F\x98\x80", buf[0..len]);
}

test "encode roundtrip all lengths" {
    const codepoints = [_]u21{ 0x00, 0x7F, 0x80, 0x7FF, 0x800, 0xFFFF, 0x10000, 0x10FFFF };
    for (codepoints) |cp| {
        var buf: [4]u8 = undefined;
        const len = encode(cp, &buf);
        const r = decode(buf[0..len]);
        try std.testing.expectEqual(cp, r.codepoint);
        try std.testing.expectEqual(len, r.len);
    }
}

test "utf8Len" {
    try std.testing.expectEqual(@as(u3, 1), utf8Len(0x00));
    try std.testing.expectEqual(@as(u3, 1), utf8Len(0x7F));
    try std.testing.expectEqual(@as(u3, 1), utf8Len(0x80)); // continuation — invalid lead
    try std.testing.expectEqual(@as(u3, 1), utf8Len(0xBF)); // continuation — invalid lead
    try std.testing.expectEqual(@as(u3, 1), utf8Len(0xC0)); // overlong range
    try std.testing.expectEqual(@as(u3, 1), utf8Len(0xC1)); // overlong range
    try std.testing.expectEqual(@as(u3, 2), utf8Len(0xC2));
    try std.testing.expectEqual(@as(u3, 2), utf8Len(0xDF));
    try std.testing.expectEqual(@as(u3, 3), utf8Len(0xE0));
    try std.testing.expectEqual(@as(u3, 3), utf8Len(0xEF));
    try std.testing.expectEqual(@as(u3, 4), utf8Len(0xF0));
    try std.testing.expectEqual(@as(u3, 4), utf8Len(0xF4));
    try std.testing.expectEqual(@as(u3, 1), utf8Len(0xF5)); // invalid
    try std.testing.expectEqual(@as(u3, 1), utf8Len(0xFF)); // invalid
}

test "countCodepoints" {
    try std.testing.expectEqual(@as(usize, 0), countCodepoints(""));
    try std.testing.expectEqual(@as(usize, 5), countCodepoints("Hello"));
    // "Héllo" — H é l l o = 5 codepoints, 6 bytes
    try std.testing.expectEqual(@as(usize, 5), countCodepoints("H\xC3\xA9llo"));
    // "世界" — 2 codepoints, 6 bytes
    try std.testing.expectEqual(@as(usize, 2), countCodepoints("\xE4\xB8\x96\xE7\x95\x8C"));
    // emoji U+1F600 = 1 codepoint, 4 bytes
    try std.testing.expectEqual(@as(usize, 1), countCodepoints("\xF0\x9F\x98\x80"));
}

test "nthCodepointOffset" {
    const s = "H\xC3\xA9llo"; // H(1) é(2) l(1) l(1) o(1) = 6 bytes
    try std.testing.expectEqual(@as(?usize, 0), nthCodepointOffset(s, 0)); // H
    try std.testing.expectEqual(@as(?usize, 1), nthCodepointOffset(s, 1)); // é
    try std.testing.expectEqual(@as(?usize, 3), nthCodepointOffset(s, 2)); // l
    try std.testing.expectEqual(@as(?usize, 4), nthCodepointOffset(s, 3)); // l
    try std.testing.expectEqual(@as(?usize, 5), nthCodepointOffset(s, 4)); // o
    try std.testing.expectEqual(@as(?usize, 6), nthCodepointOffset(s, 5)); // one past end
    try std.testing.expectEqual(@as(?usize, null), nthCodepointOffset(s, 6)); // out of range
}

test "nthCodepointOffset empty" {
    try std.testing.expectEqual(@as(?usize, 0), nthCodepointOffset("", 0));
    try std.testing.expectEqual(@as(?usize, null), nthCodepointOffset("", 1));
}

test "validate valid UTF-8" {
    try std.testing.expect(validate(""));
    try std.testing.expect(validate("ASCII only"));
    try std.testing.expect(validate("H\xC3\xA9llo"));
    try std.testing.expect(validate("\xE4\xB8\x96\xE7\x95\x8C"));
    try std.testing.expect(validate("\xF0\x9F\x98\x80"));
    try std.testing.expect(validate(&[_]u8{0x00})); // null byte is valid
}

test "validate actual U+FFFD is valid" {
    // The actual encoding of U+FFFD: EF BF BD
    try std.testing.expect(validate("\xEF\xBF\xBD"));
}

test "validate invalid UTF-8" {
    try std.testing.expect(!validate(&[_]u8{0xFF}));
    try std.testing.expect(!validate(&[_]u8{0xFE}));
    try std.testing.expect(!validate(&[_]u8{0x80})); // lone continuation
    try std.testing.expect(!validate(&[_]u8{0xC3})); // truncated
    try std.testing.expect(!validate("\xC0\xAF")); // overlong
    try std.testing.expect(!validate("\xED\xA0\x80")); // surrogate
    try std.testing.expect(!validate("abc\xFEdef")); // invalid byte mid-string
}

test "isContByte" {
    try std.testing.expect(!isContByte(0x00));
    try std.testing.expect(!isContByte(0x7F));
    try std.testing.expect(isContByte(0x80));
    try std.testing.expect(isContByte(0xBF));
    try std.testing.expect(!isContByte(0xC0));
    try std.testing.expect(!isContByte(0xFF));
}
