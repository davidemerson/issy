//! Font loading and glyph metrics.
//!
//! Parses TrueType/OpenType font files to extract glyph metrics for
//! text measurement and PDF font embedding. Supports cmap lookup, glyph
//! advance widths, and retains raw font data for embedding.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const FontError = error{
    InvalidFont,
    MissingTable,
    UnsupportedFormat,
    FileNotFound,
    ReadError,
    OutOfMemory,
    PathTooLong,
};

pub const Font = struct {
    family_name: [256]u8 = std.mem.zeroes([256]u8),
    family_name_len: usize = 0,
    style_name: [256]u8 = std.mem.zeroes([256]u8),
    style_name_len: usize = 0,
    is_otf: bool = false,
    units_per_em: u16 = 1000,
    ascender: i16 = 800,
    descender: i16 = -200,
    line_gap: i16 = 0,
    cap_height: i16 = 700,
    num_glyphs: u16 = 0,
    glyph_widths: []i16 = &.{},
    cmap: []u16 = &.{},
    x_min: i16 = 0,
    y_min: i16 = 0,
    x_max: i16 = 1000,
    y_max: i16 = 1000,
    is_fixed_pitch: bool = false,
    data: []const u8 = &.{},
    allocator: Allocator,

    pub fn load(allocator: Allocator, path: []const u8) FontError!Font {
        const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
        defer file.close();

        const stat = file.stat() catch return error.ReadError;
        const file_size: usize = @intCast(stat.size);
        if (file_size < 12) return error.InvalidFont;

        const data = allocator.alloc(u8, file_size) catch return error.OutOfMemory;
        errdefer allocator.free(data);

        const bytes_read = file.readAll(data) catch return error.ReadError;
        if (bytes_read != file_size) return error.ReadError;

        var font = Font{ .allocator = allocator, .data = data };

        // Detect format
        const sf_version = readU32(data, 0);
        if (sf_version == 0x4F54544F) {
            font.is_otf = true; // "OTTO" - OTF with CFF outlines
        } else if (sf_version == 0x00010000 or sf_version == 0x74727565) {
            font.is_otf = false; // TTF
        } else {
            return error.InvalidFont;
        }

        // Parse table directory
        const num_tables = readU16(data, 4);

        // Allocate cmap and glyph_widths
        font.cmap = allocator.alloc(u16, 65536) catch return error.OutOfMemory;
        errdefer allocator.free(font.cmap);
        @memset(font.cmap, 0);

        try font.parseTables(data, num_tables);

        return font;
    }

    fn parseTables(self: *Font, data: []const u8, num_tables: u16) FontError!void {
        var head_off: ?usize = null;
        var hhea_off: ?usize = null;
        var hmtx_off: ?usize = null;
        var maxp_off: ?usize = null;
        var os2_off: ?usize = null;
        var name_off: ?usize = null;
        var cmap_off: ?usize = null;
        var post_off: ?usize = null;

        var i: usize = 0;
        while (i < num_tables) : (i += 1) {
            const entry = 12 + i * 16;
            if (entry + 16 > data.len) break;

            const tag = data[entry..][0..4];
            const offset: usize = @intCast(readU32(data, entry + 8));

            if (std.mem.eql(u8, tag, "head")) head_off = offset
            else if (std.mem.eql(u8, tag, "hhea")) hhea_off = offset
            else if (std.mem.eql(u8, tag, "hmtx")) hmtx_off = offset
            else if (std.mem.eql(u8, tag, "maxp")) maxp_off = offset
            else if (std.mem.eql(u8, tag, "OS/2")) os2_off = offset
            else if (std.mem.eql(u8, tag, "name")) name_off = offset
            else if (std.mem.eql(u8, tag, "cmap")) cmap_off = offset
            else if (std.mem.eql(u8, tag, "post")) post_off = offset;
        }

        // head table
        if (head_off) |off| {
            if (off + 54 <= data.len) {
                self.units_per_em = readU16(data, off + 18);
                self.x_min = readI16(data, off + 36);
                self.y_min = readI16(data, off + 38);
                self.x_max = readI16(data, off + 40);
                self.y_max = readI16(data, off + 42);
            }
        }

        // maxp table
        if (maxp_off) |off| {
            if (off + 6 <= data.len) {
                self.num_glyphs = readU16(data, off + 4);
            }
        }

        // hhea table
        var num_h_metrics: u16 = 0;
        if (hhea_off) |off| {
            if (off + 36 <= data.len) {
                self.ascender = readI16(data, off + 4);
                self.descender = readI16(data, off + 6);
                self.line_gap = readI16(data, off + 8);
                num_h_metrics = readU16(data, off + 34);
            }
        }

        // OS/2 table (overrides hhea metrics)
        if (os2_off) |off| {
            if (off + 78 <= data.len) {
                const version = readU16(data, off);
                self.ascender = readI16(data, off + 68);
                self.descender = readI16(data, off + 70);
                self.line_gap = readI16(data, off + 72);
                if (version >= 2 and off + 90 <= data.len) {
                    self.cap_height = readI16(data, off + 88);
                } else {
                    self.cap_height = self.ascender;
                }
            }
        }

        // hmtx table
        if (hmtx_off) |off| {
            self.glyph_widths = self.allocator.alloc(i16, self.num_glyphs) catch return error.OutOfMemory;
            @memset(self.glyph_widths, 0);

            var last_width: i16 = 0;
            var g: usize = 0;
            while (g < num_h_metrics and g < self.num_glyphs) : (g += 1) {
                const entry_off = off + g * 4;
                if (entry_off + 2 <= data.len) {
                    last_width = @bitCast(readU16(data, entry_off));
                    self.glyph_widths[g] = last_width;
                }
            }
            // Remaining glyphs get the last width
            while (g < self.num_glyphs) : (g += 1) {
                self.glyph_widths[g] = last_width;
            }
        }

        // name table
        if (name_off) |off| {
            self.parseName(data, off);
        }

        // cmap table
        if (cmap_off) |off| {
            self.parseCmap(data, off);
        }

        // post table
        if (post_off) |off| {
            if (off + 16 <= data.len) {
                const fixed_pitch = readU32(data, off + 12);
                self.is_fixed_pitch = fixed_pitch != 0;
            }
        }
    }

    fn parseName(self: *Font, data: []const u8, off: usize) void {
        if (off + 6 > data.len) return;
        const count = readU16(data, off + 2);
        const string_off = off + @as(usize, readU16(data, off + 4));

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const rec = off + 6 + i * 12;
            if (rec + 12 > data.len) break;

            const platform_id = readU16(data, rec);
            const name_id = readU16(data, rec + 6);
            const str_length = readU16(data, rec + 8);
            const str_off = string_off + @as(usize, readU16(data, rec + 10));

            if (str_off + str_length > data.len) continue;

            // Prefer Windows platform (3)
            if (platform_id == 3) {
                const str_data = data[str_off..][0..str_length];
                if (name_id == 1 and self.family_name_len == 0) {
                    self.family_name_len = decodeUtf16BE(str_data, &self.family_name);
                } else if (name_id == 2 and self.style_name_len == 0) {
                    self.style_name_len = decodeUtf16BE(str_data, &self.style_name);
                }
            } else if (platform_id == 1) {
                // Mac fallback
                if (name_id == 1 and self.family_name_len == 0) {
                    const len = @min(str_length, 256);
                    @memcpy(self.family_name[0..len], data[str_off..][0..len]);
                    self.family_name_len = len;
                } else if (name_id == 2 and self.style_name_len == 0) {
                    const len = @min(str_length, 256);
                    @memcpy(self.style_name[0..len], data[str_off..][0..len]);
                    self.style_name_len = len;
                }
            }
        }
    }

    fn parseCmap(self: *Font, data: []const u8, off: usize) void {
        if (off + 4 > data.len) return;
        const num_subtables = readU16(data, off + 2);

        var i: usize = 0;
        while (i < num_subtables) : (i += 1) {
            const rec = off + 4 + i * 8;
            if (rec + 8 > data.len) break;

            const platform_id = readU16(data, rec);
            const encoding_id = readU16(data, rec + 2);
            const subtable_off = off + @as(usize, readU32(data, rec + 4));

            if (platform_id == 3 and encoding_id == 1) {
                if (subtable_off + 6 <= data.len) {
                    const format = readU16(data, subtable_off);
                    if (format == 4) {
                        self.parseCmapFormat4(data, subtable_off);
                        return;
                    }
                }
            }
        }
    }

    fn parseCmapFormat4(self: *Font, data: []const u8, off: usize) void {
        if (off + 14 > data.len) return;

        const seg_count_x2 = readU16(data, off + 6);
        const seg_count = seg_count_x2 / 2;

        const end_codes_off = off + 14;
        const start_codes_off = end_codes_off + seg_count_x2 + 2; // +2 for reservedPad
        const id_delta_off = start_codes_off + seg_count_x2;
        const id_range_off = id_delta_off + seg_count_x2;

        if (id_range_off + seg_count_x2 > data.len) return;

        var seg: usize = 0;
        while (seg < seg_count) : (seg += 1) {
            const end_code = readU16(data, end_codes_off + seg * 2);
            const start_code = readU16(data, start_codes_off + seg * 2);
            const id_delta: i16 = readI16(data, id_delta_off + seg * 2);
            const id_range_offset = readU16(data, id_range_off + seg * 2);

            if (start_code == 0xFFFF) break;

            var c: u32 = start_code;
            while (c <= end_code and c < 65536) : (c += 1) {
                var glyph_id: u16 = undefined;
                if (id_range_offset == 0) {
                    glyph_id = @bitCast(@as(i16, @bitCast(@as(u16, @intCast(c)))) +% id_delta);
                } else {
                    const range_base = id_range_off + seg * 2;
                    const glyph_off = range_base + id_range_offset + (c - start_code) * 2;
                    if (glyph_off + 2 <= data.len) {
                        glyph_id = readU16(data, glyph_off);
                        if (glyph_id != 0) {
                            glyph_id = @bitCast(@as(i16, @bitCast(glyph_id)) +% id_delta);
                        }
                    } else {
                        glyph_id = 0;
                    }
                }
                self.cmap[@intCast(c)] = glyph_id;
            }
        }
    }

    pub fn deinit(self: *Font) void {
        if (self.glyph_widths.len > 0) self.allocator.free(self.glyph_widths);
        if (self.cmap.len > 0) self.allocator.free(self.cmap);
        if (self.data.len > 0) self.allocator.free(@constCast(self.data));
    }

    pub fn glyphId(self: *const Font, codepoint: u21) u16 {
        if (codepoint > 0xFFFF) return 0;
        if (self.cmap.len == 0) return 0;
        return self.cmap[@intCast(codepoint)];
    }

    pub fn charWidth(self: *const Font, codepoint: u21, font_size_pt: f32) f32 {
        const gid = self.glyphId(codepoint);
        if (gid >= self.glyph_widths.len) return 0;
        return @as(f32, @floatFromInt(self.glyph_widths[gid])) * font_size_pt / @as(f32, @floatFromInt(self.units_per_em));
    }

    pub fn stringWidth(self: *const Font, str: []const u8, font_size_pt: f32) f32 {
        var total: f32 = 0;
        var i: usize = 0;
        while (i < str.len) {
            const b = str[i];
            var cp: u21 = undefined;
            var len: usize = 1;
            if (b < 0x80) {
                cp = b;
            } else if (b < 0xE0 and i + 1 < str.len) {
                cp = (@as(u21, b & 0x1F) << 6) | @as(u21, str[i + 1] & 0x3F);
                len = 2;
            } else if (b < 0xF0 and i + 2 < str.len) {
                cp = (@as(u21, b & 0x0F) << 12) | (@as(u21, str[i + 1] & 0x3F) << 6) | @as(u21, str[i + 2] & 0x3F);
                len = 3;
            } else if (i + 3 < str.len) {
                cp = (@as(u21, b & 0x07) << 18) | (@as(u21, str[i + 1] & 0x3F) << 12) | (@as(u21, str[i + 2] & 0x3F) << 6) | @as(u21, str[i + 3] & 0x3F);
                len = 4;
            } else {
                cp = 0xFFFD;
            }
            total += self.charWidth(cp, font_size_pt);
            i += len;
        }
        return total;
    }

    pub fn lineHeight(self: *const Font, font_size_pt: f32) f32 {
        return @as(f32, @floatFromInt(self.ascender - self.descender + self.line_gap)) * font_size_pt / @as(f32, @floatFromInt(self.units_per_em));
    }

    pub fn familyName(self: *const Font) []const u8 {
        return self.family_name[0..self.family_name_len];
    }

    pub fn styleName(self: *const Font) []const u8 {
        return self.style_name[0..self.style_name_len];
    }
};

// ── Big-endian helpers ──

pub fn readU16(buf: []const u8, offset: usize) u16 {
    if (offset + 2 > buf.len) return 0;
    return std.mem.readInt(u16, buf[offset..][0..2], .big);
}

pub fn readI16(buf: []const u8, offset: usize) i16 {
    if (offset + 2 > buf.len) return 0;
    return std.mem.readInt(i16, buf[offset..][0..2], .big);
}

pub fn readU32(buf: []const u8, offset: usize) u32 {
    if (offset + 4 > buf.len) return 0;
    return std.mem.readInt(u32, buf[offset..][0..4], .big);
}

pub fn readI32(buf: []const u8, offset: usize) i32 {
    if (offset + 4 > buf.len) return 0;
    return std.mem.readInt(i32, buf[offset..][0..4], .big);
}

fn decodeUtf16BE(src: []const u8, dst: *[256]u8) usize {
    var out: usize = 0;
    var i: usize = 0;
    while (i + 1 < src.len and out < 255) {
        const ch = std.mem.readInt(u16, src[i..][0..2], .big);
        if (ch < 128) {
            dst[out] = @intCast(ch);
            out += 1;
        }
        i += 2;
    }
    return out;
}

// ── Tests ──

test "big-endian readers" {
    const data = [_]u8{ 0x00, 0x01, 0x00, 0x02 };
    try std.testing.expectEqual(@as(u16, 1), readU16(&data, 0));
    try std.testing.expectEqual(@as(u16, 2), readU16(&data, 2));
    try std.testing.expectEqual(@as(u32, 0x00010002), readU32(&data, 0));
}

test "big-endian signed" {
    const data = [_]u8{ 0xFF, 0xFE }; // -2 in big-endian i16
    try std.testing.expectEqual(@as(i16, -2), readI16(&data, 0));
}

test "load returns error for empty file" {
    // We can't easily create a temp file in a test, so test the error path
    const result = Font.load(std.testing.allocator, "/nonexistent/font.ttf");
    try std.testing.expectError(error.FileNotFound, result);
}

test "font metrics calculations" {
    // Create a minimal font struct for testing
    var widths = [_]i16{ 500, 600, 700 };
    var cmap_data = [_]u16{0} ** 65536;
    cmap_data['A'] = 1;
    cmap_data['B'] = 2;

    var font = Font{
        .allocator = std.testing.allocator,
        .units_per_em = 1000,
        .ascender = 800,
        .descender = -200,
        .line_gap = 0,
        .glyph_widths = &widths,
        .cmap = &cmap_data,
    };

    // charWidth
    const w = font.charWidth('A', 12.0);
    try std.testing.expectApproxEqAbs(@as(f32, 7.2), w, 0.01);

    // lineHeight
    const lh = font.lineHeight(12.0);
    try std.testing.expectApproxEqAbs(@as(f32, 12.0), lh, 0.01);

    // glyphId
    try std.testing.expectEqual(@as(u16, 1), font.glyphId('A'));
    try std.testing.expectEqual(@as(u16, 0), font.glyphId(0x10000)); // beyond BMP

    // Don't call deinit since we didn't allocate
    _ = &font;
}
