//! Print and PDF export.
//!
//! Generates PDF 1.4 output from the editor buffer with font embedding.
//! Uses white paper with its own color mapping tuned for ink — never
//! inherits the dark TUI theme.

const std = @import("std");
const Allocator = std.mem.Allocator;
const editor_mod = @import("editor.zig");
const config_mod = @import("config.zig");
const font_mod = @import("font.zig");
const syntax_mod = @import("syntax.zig");
const unicode = @import("unicode.zig");

const MAX_WRAP_BREAKS = editor_mod.Editor.MAX_WRAP_BREAKS;

const PdfWriter = struct {
    out: std.ArrayList(u8),
    offsets: std.ArrayList(usize),
    obj_count: usize = 0,
    allocator: Allocator,

    fn init(allocator: Allocator) PdfWriter {
        return .{
            .out = .{},
            .offsets = .{},
            .allocator = allocator,
        };
    }

    fn deinit(self: *PdfWriter) void {
        self.out.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
    }

    fn beginObj(self: *PdfWriter) usize {
        self.obj_count += 1;
        self.offsets.append(self.allocator, self.out.items.len) catch {};
        self.writeFmt("{d} 0 obj\n", .{self.obj_count});
        return self.obj_count;
    }

    fn endObj(self: *PdfWriter) void {
        self.writeRaw("endobj\n");
    }

    fn writeRaw(self: *PdfWriter, data: []const u8) void {
        self.out.appendSlice(self.allocator, data) catch {};
    }

    fn writeFmt(self: *PdfWriter, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.writeRaw(s);
    }
};

pub fn toPdf(ed: *editor_mod.Editor, output_path: []const u8) !void {
    const cfg = ed.config;
    const font_path = cfg.fontFilePath() orelse return error.NoFontConfigured;

    var fnt = try font_mod.Font.load(ed.allocator, font_path);
    defer fnt.deinit();

    var pdf = PdfWriter.init(ed.allocator);
    defer pdf.deinit();

    // Sanitize font name for PDF Name objects (no spaces allowed)
    var pdf_font_name: [256]u8 = undefined;
    const raw_name = fnt.familyName();
    var name_len: usize = 0;
    for (raw_name) |c| {
        if (name_len >= 256) break;
        pdf_font_name[name_len] = if (c == ' ') '-' else c;
        name_len += 1;
    }
    const font_name = pdf_font_name[0..name_len];

    // Header
    pdf.writeRaw("%PDF-1.4\n%\xc3\xa4\xc3\xbc\xc3\xb6\xc3\x9f\n");

    // Obj 1: Catalog
    _ = pdf.beginObj();
    pdf.writeRaw("<< /Type /Catalog /Pages 2 0 R >>\n");
    pdf.endObj();

    // Reserve obj 2 for Pages — written at the end once we know the page list.
    // Just increment the counter and add a placeholder offset.
    pdf.obj_count += 1;
    pdf.offsets.append(pdf.allocator, 0) catch {}; // will be overwritten

    // Obj 3: FontDescriptor
    _ = pdf.beginObj();
    const scale = @as(f32, 1000.0) / @as(f32, @floatFromInt(fnt.units_per_em));
    pdf.writeRaw("<< /Type /FontDescriptor\n");
    pdf.writeFmt("/FontName /{s}\n", .{font_name});
    pdf.writeRaw("/Flags 37\n");
    pdf.writeFmt("/FontBBox [{d} {d} {d} {d}]\n", .{
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.x_min)) * scale)),
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.y_min)) * scale)),
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.x_max)) * scale)),
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.y_max)) * scale)),
    });
    pdf.writeRaw("/ItalicAngle 0\n");
    pdf.writeFmt("/Ascent {d}\n", .{@as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.ascender)) * scale))});
    pdf.writeFmt("/Descent {d}\n", .{@as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.descender)) * scale))});
    pdf.writeFmt("/CapHeight {d}\n", .{@as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.cap_height)) * scale))});
    pdf.writeRaw("/StemV 80\n");
    if (fnt.is_otf) {
        pdf.writeRaw("/FontFile3 4 0 R\n");
    } else {
        pdf.writeRaw("/FontFile2 4 0 R\n");
    }
    pdf.writeRaw(">>\n");
    pdf.endObj();

    // Obj 4: Font file stream
    _ = pdf.beginObj();
    pdf.writeFmt("<< /Length {d}", .{fnt.data.len});
    if (fnt.is_otf) {
        pdf.writeRaw(" /Subtype /OpenType");
    }
    pdf.writeRaw(" >>\nstream\n");
    pdf.writeRaw(fnt.data);
    pdf.writeRaw("\nendstream\n");
    pdf.endObj();

    // Obj 5: CIDFont
    _ = pdf.beginObj();
    pdf.writeRaw("<< /Type /Font\n");
    if (fnt.is_otf) {
        pdf.writeRaw("/Subtype /CIDFontType0\n");
    } else {
        pdf.writeRaw("/Subtype /CIDFontType2\n");
    }
    pdf.writeFmt("/BaseFont /{s}\n", .{font_name});
    pdf.writeRaw("/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>\n");
    pdf.writeRaw("/FontDescriptor 3 0 R\n");
    // Default width
    pdf.writeFmt("/DW {d}\n", .{@as(i32, @intFromFloat(@as(f32, @floatFromInt(if (fnt.glyph_widths.len > 0) fnt.glyph_widths[0] else 500)) * scale))});
    pdf.writeRaw(">>\n");
    pdf.endObj();

    // Obj 6: ToUnicode CMap (simplified)
    _ = pdf.beginObj();
    const cmap_str =
        "/CIDInit /ProcSet findresource begin\n" ++
        "12 dict begin\n" ++
        "begincmap\n" ++
        "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> def\n" ++
        "/CMapName /Adobe-Identity-UCS def\n" ++
        "/CMapType 2 def\n" ++
        "1 begincodespacerange\n" ++
        "<0000> <FFFF>\n" ++
        "endcodespacerange\n" ++
        "1 beginbfrange\n" ++
        "<0000> <FFFF> <0000>\n" ++
        "endbfrange\n" ++
        "endcmap\n" ++
        "CMapName currentdict /CMap defineresource pop\n" ++
        "end\n" ++
        "end\n";
    pdf.writeFmt("<< /Length {d} >>\nstream\n", .{cmap_str.len});
    pdf.writeRaw(cmap_str);
    pdf.writeRaw("\nendstream\n");
    pdf.endObj();

    // Obj 7: Type0 font
    _ = pdf.beginObj();
    pdf.writeRaw("<< /Type /Font /Subtype /Type0\n");
    pdf.writeFmt("/BaseFont /{s}\n", .{font_name});
    pdf.writeRaw("/Encoding /Identity-H\n");
    pdf.writeRaw("/DescendantFonts [5 0 R]\n");
    pdf.writeRaw("/ToUnicode 6 0 R\n");
    pdf.writeRaw(">>\n");
    pdf.endObj();

    // Generate pages
    var page_obj_ids: std.ArrayList(usize) = .{};
    defer page_obj_ids.deinit(ed.allocator);

    const font_size = cfg.font_size;
    const line_height = fnt.lineHeight(font_size) * 1.3;
    const page_w: f32 = 612.0;
    const page_h: f32 = 792.0;
    const margin_top = cfg.print_margin_top;
    const margin_bottom = cfg.print_margin_bottom;
    const margin_left = cfg.print_margin_left;
    const margin_right = cfg.print_margin_right;

    // Content width in points and continuation indent (2 spaces, mirrors TUI).
    const space_w: f32 = @max(fnt.charWidth(' ', font_size), font_size * 0.25);
    const content_w: f32 = @max(page_w - margin_left - margin_right, space_w);
    const cont_indent_pts: f32 = space_w * 2;
    const cont_w: f32 = @max(content_w - cont_indent_pts, space_w);
    const tw = ed.effectiveTabWidth();

    var y: f32 = page_h - margin_top;
    var page_lines: std.ArrayList(u8) = .{};
    defer page_lines.deinit(ed.allocator);

    const total_lines = ed.buf.lineCount();
    var line_num: usize = 0;
    var sub_start_idx: usize = 0; // resume index when a line wraps across a page

    while (line_num < total_lines) {
        // Start a new page content stream
        page_lines.clearRetainingCapacity();
        y = page_h - margin_top;

        // Content
        appendFmt(&page_lines, ed.allocator, "BT\n/F1 {d:.1} Tf\n", .{font_size});
        appendFmt(&page_lines, ed.allocator, "{d:.1} {d:.1} Td\n", .{ margin_left, y });

        // Set color once per page (cheaper than per line).
        const pt = config_mod.print_theme;
        writeColor(&page_lines, ed.allocator, pt.fg);
        page_lines.appendSlice(ed.allocator, " rg\n") catch {};

        // Track the x origin of the current line matrix so we can compute
        // the relative dx for the next Td when indenting continuations.
        var last_origin_x: f32 = margin_left;

        while (line_num < total_lines and y > margin_bottom) {
            const line_info = ed.buf.getLine(line_num) orelse {
                line_num += 1;
                sub_start_idx = 0;
                continue;
            };
            var line_tmp: [4096]u8 = undefined;
            const line_data = ed.buf.contiguousSlice(line_info.start, @min(line_info.len, 4096), &line_tmp);

            var breaks: [MAX_WRAP_BREAKS]usize = undefined;
            const break_count = computePdfWrapBreaks(&fnt, font_size, line_data, content_w, cont_w, tw, &breaks);

            var si: usize = sub_start_idx;
            while (si < break_count and y > margin_bottom) : (si += 1) {
                const sub_start = breaks[si];
                const sub_end = if (si + 1 < break_count) breaks[si + 1] else line_data.len;

                const target_x: f32 = if (si == 0) margin_left else margin_left + cont_indent_pts;
                const dx = target_x - last_origin_x;
                appendFmt(&page_lines, ed.allocator, "{d:.2} {d:.2} Td\n", .{ dx, -line_height });
                last_origin_x = target_x;

                // Encode text as hex glyph IDs (decode UTF-8 properly; tabs expand to spaces).
                page_lines.appendSlice(ed.allocator, "<") catch {};
                encodeGlyphs(&page_lines, ed.allocator, &fnt, line_data[sub_start..sub_end], tw);
                page_lines.appendSlice(ed.allocator, "> Tj\n") catch {};

                y -= line_height;
            }

            if (si < break_count) {
                // Out of vertical space — resume this line on the next page.
                sub_start_idx = si;
                break;
            }

            sub_start_idx = 0;
            line_num += 1;
        }

        page_lines.appendSlice(ed.allocator, "ET\n") catch {};

        // Content stream object
        const content_obj = pdf.beginObj();
        pdf.writeFmt("<< /Length {d} >>\nstream\n", .{page_lines.items.len});
        pdf.writeRaw(page_lines.items);
        pdf.writeRaw("\nendstream\n");
        pdf.endObj();

        // Page object
        const page_obj = pdf.beginObj();
        pdf.writeRaw("<< /Type /Page /Parent 2 0 R\n");
        pdf.writeFmt("/MediaBox [0 0 {d:.0} {d:.0}]\n", .{ page_w, page_h });
        pdf.writeFmt("/Contents {d} 0 R\n", .{content_obj});
        pdf.writeRaw("/Resources << /Font << /F1 7 0 R >> >>\n");
        pdf.writeRaw(">>\n");
        pdf.endObj();

        page_obj_ids.append(ed.allocator, page_obj) catch {};
    }

    // If no pages were generated, create one empty page
    if (page_obj_ids.items.len == 0) {
        const content_obj = pdf.beginObj();
        pdf.writeRaw("<< /Length 0 >>\nstream\n\nendstream\n");
        pdf.endObj();

        const page_obj = pdf.beginObj();
        pdf.writeRaw("<< /Type /Page /Parent 2 0 R\n");
        pdf.writeFmt("/MediaBox [0 0 {d:.0} {d:.0}]\n", .{ page_w, page_h });
        pdf.writeFmt("/Contents {d} 0 R\n", .{content_obj});
        pdf.writeRaw("/Resources << /Font << /F1 7 0 R >> >>\n");
        pdf.writeRaw(">>\n");
        pdf.endObj();

        page_obj_ids.append(ed.allocator, page_obj) catch {};
    }

    // Write Pages object (obj 2) — now that we know the page list
    pdf.offsets.items[1] = pdf.out.items.len; // obj 2 is at offsets index 1
    pdf.writeFmt("2 0 obj\n<< /Type /Pages /Kids [", .{});
    for (page_obj_ids.items) |pid| {
        pdf.writeFmt("{d} 0 R ", .{pid});
    }
    pdf.writeFmt("] /Count {d} >>\nendobj\n", .{page_obj_ids.items.len});

    // xref table
    const xref_offset = pdf.out.items.len;
    pdf.writeRaw("xref\n");
    pdf.writeFmt("0 {d}\n", .{pdf.obj_count + 1});
    pdf.writeRaw("0000000000 65535 f \n");
    for (pdf.offsets.items) |off| {
        pdf.writeFmt("{d:0>10} 00000 n \n", .{off});
    }

    // Trailer
    pdf.writeRaw("trailer\n");
    pdf.writeFmt("<< /Size {d} /Root 1 0 R >>\n", .{pdf.obj_count + 1});
    pdf.writeRaw("startxref\n");
    pdf.writeFmt("{d}\n", .{xref_offset});
    pdf.writeRaw("%%EOF\n");

    // Write to file
    const file = try std.fs.cwd().createFile(output_path, .{});
    defer file.close();
    try file.writeAll(pdf.out.items);
}

fn writeColor(list: *std.ArrayList(u8), allocator: Allocator, color: config_mod.Color) void {
    switch (color) {
        .rgb => |c| {
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3}", .{
                @as(f32, @floatFromInt(c.r)) / 255.0,
                @as(f32, @floatFromInt(c.g)) / 255.0,
                @as(f32, @floatFromInt(c.b)) / 255.0,
            }) catch return;
            list.appendSlice(allocator, s) catch {};
        },
        else => {
            list.appendSlice(allocator, "0.180 0.180 0.180") catch {};
        },
    }
}

fn appendFmt(list: *std.ArrayList(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    list.appendSlice(allocator, s) catch {};
}

fn isBreakAfter(ch: u8) bool {
    return switch (ch) {
        ',', ';', ')', ']', '}', '.', ':', '-', '/', '\\', '|', '&', '+', '=', '>' => true,
        else => false,
    };
}

/// Decode the next UTF-8 codepoint at `data[i]`, returning codepoint and byte length.
fn nextCodepoint(data: []const u8, i: usize) struct { cp: u21, len: usize } {
    const b0 = data[i];
    if (b0 < 0x80) return .{ .cp = b0, .len = 1 };
    if (b0 < 0xE0 and i + 1 < data.len) {
        return .{
            .cp = (@as(u21, b0 & 0x1F) << 6) | @as(u21, data[i + 1] & 0x3F),
            .len = 2,
        };
    }
    if (b0 < 0xF0 and i + 2 < data.len) {
        return .{
            .cp = (@as(u21, b0 & 0x0F) << 12) | (@as(u21, data[i + 1] & 0x3F) << 6) | @as(u21, data[i + 2] & 0x3F),
            .len = 3,
        };
    }
    if (i + 3 < data.len) {
        return .{
            .cp = (@as(u21, b0 & 0x07) << 18) | (@as(u21, data[i + 1] & 0x3F) << 12) | (@as(u21, data[i + 2] & 0x3F) << 6) | @as(u21, data[i + 3] & 0x3F),
            .len = 4,
        };
    }
    return .{ .cp = 0xFFFD, .len = 1 };
}

/// Compute wrap break points for a single buffer line, measuring in real
/// font points. Mirrors editor.zig's computeWrapBreaks typesetting rules:
/// prefer last space, then last break-after punctuation, only accept a
/// candidate past the 60% threshold, fall back to a hard break, and
/// guarantee forward progress on runs of unbreakable glyphs.
fn computePdfWrapBreaks(
    fnt: *const font_mod.Font,
    font_size: f32,
    data: []const u8,
    first_w: f32,
    cont_w: f32,
    tab_width: u8,
    breaks: *[MAX_WRAP_BREAKS]usize,
) usize {
    breaks[0] = 0;
    const space_w = fnt.charWidth(' ', font_size);
    var count: usize = 1;
    var pos: usize = 0;
    var first = true;

    while (pos < data.len and count < MAX_WRAP_BREAKS) {
        const avail = if (first) first_w else cont_w;
        first = false;

        var width_so_far: f32 = 0;
        var visual_col: usize = 0;
        var i: usize = pos;
        var last_space_byte: ?usize = null;
        var last_space_width: f32 = 0;
        var last_punct_byte: ?usize = null;
        var last_punct_width: f32 = 0;

        while (i < data.len) {
            const b = data[i];
            if (b == '\n' or b == '\r') break;

            var cp_width: f32 = 0;
            var cp_visual: usize = 1;
            var byte_len: usize = 1;

            if (b == '\t') {
                const advance = tab_width - @as(u8, @intCast(visual_col % tab_width));
                cp_width = space_w * @as(f32, @floatFromInt(advance));
                cp_visual = advance;
                byte_len = 1;
            } else {
                const dec = nextCodepoint(data, i);
                cp_width = fnt.charWidth(dec.cp, font_size);
                byte_len = dec.len;
            }

            if (width_so_far + cp_width > avail) break;

            width_so_far += cp_width;
            visual_col += cp_visual;
            i += byte_len;

            if (b == ' ' or b == '\t') {
                last_space_byte = i;
                last_space_width = width_so_far;
            } else if (isBreakAfter(b)) {
                last_punct_byte = i;
                last_punct_width = width_so_far;
            }
        }

        if (i >= data.len or data[i] == '\n' or data[i] == '\r') break;

        const min_width = avail * 3.0 / 5.0;
        var break_at: usize = i;
        if (last_space_byte) |bp| {
            if (last_space_width >= min_width) break_at = bp;
        } else if (last_punct_byte) |bp| {
            if (last_punct_width >= min_width) break_at = bp;
        }

        // Forward-progress guard for runs of unbreakable codepoints wider than avail.
        if (break_at <= pos) {
            const blen = @max(@as(usize, unicode.utf8Len(data[pos])), 1);
            break_at = pos + blen;
        }

        breaks[count] = break_at;
        count += 1;
        pos = break_at;
    }

    return count;
}

/// Encode a byte slice as hex glyph IDs into `list`. Tabs expand to
/// `tab_width` space glyphs so they don't render as .notdef. CR/LF
/// terminators (if present) are skipped.
fn encodeGlyphs(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    fnt: *const font_mod.Font,
    data: []const u8,
    tab_width: u8,
) void {
    const space_gid = fnt.glyphId(' ');
    var bi: usize = 0;
    while (bi < data.len) {
        const b0 = data[bi];
        if (b0 == '\n' or b0 == '\r') {
            bi += 1;
            continue;
        }
        if (b0 == '\t') {
            var k: u8 = 0;
            while (k < tab_width) : (k += 1) {
                var hex_buf: [4]u8 = undefined;
                const s = std.fmt.bufPrint(&hex_buf, "{X:0>4}", .{space_gid}) catch break;
                list.appendSlice(allocator, s) catch {};
            }
            bi += 1;
            continue;
        }
        const dec = nextCodepoint(data, bi);
        const gid = fnt.glyphId(dec.cp);
        var hex_buf: [4]u8 = undefined;
        if (std.fmt.bufPrint(&hex_buf, "{X:0>4}", .{gid})) |s| {
            list.appendSlice(allocator, s) catch {};
        } else |_| {}
        bi += dec.len;
    }
}

/// Send the current editor buffer to the system default printer.
pub fn toPrinter(ed: *editor_mod.Editor) !void {
    // Write PDF to temp file, then spawn lpr
    var tmp_path: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&tmp_path, "/tmp/issy_print_{d}.pdf", .{std.time.milliTimestamp()}) catch return error.PathTooLong;
    try toPdf(ed, path);

    var child = std.process.Child.init(&.{ "lpr", path }, ed.allocator);
    _ = child.spawnAndWait() catch return error.PrintFailed;
}

// ── Tests ──

test "pdf writer basic" {
    var pdf = PdfWriter.init(std.testing.allocator);
    defer pdf.deinit();

    pdf.writeRaw("%PDF-1.4\n");
    _ = pdf.beginObj();
    pdf.writeRaw("<< /Type /Catalog >>\n");
    pdf.endObj();

    try std.testing.expect(pdf.out.items.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, pdf.out.items, "%PDF-1.4"));
}
