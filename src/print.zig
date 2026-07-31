//! Print and PDF export.
//!
//! Generates PDF 1.4 output from the editor buffer with font embedding,
//! per-token syntax colors from the print theme, page headers, and
//! automatic page breaks. Uses white paper with its own color mapping
//! tuned for ink — never inherits the dark TUI theme.

const std = @import("std");
const fsx = @import("fsx.zig");
const Allocator = std.mem.Allocator;
const editor_mod = @import("editor.zig");
const config_mod = @import("config.zig");
const font_mod = @import("font.zig");
const syntax_mod = @import("syntax.zig");
const unicode = @import("unicode.zig");

const MAX_WRAP_BREAKS = editor_mod.Editor.MAX_WRAP_BREAKS;

/// Longest line (in bytes) rendered to the PDF; the tail of longer lines
/// is dropped. Matches the TUI renderer's per-line cap.
const max_line_bytes = 8192;

const PdfWriter = struct {
    out: std.ArrayList(u8),
    offsets: std.ArrayList(usize),
    obj_count: usize = 0,
    allocator: Allocator,

    fn init(allocator: Allocator) PdfWriter {
        return .{
            .out = .empty,
            .offsets = .empty,
            .allocator = allocator,
        };
    }

    fn deinit(self: *PdfWriter) void {
        self.out.deinit(self.allocator);
        self.offsets.deinit(self.allocator);
    }

    fn beginObj(self: *PdfWriter) !usize {
        self.obj_count += 1;
        try self.offsets.append(self.allocator, self.out.items.len);
        try self.writeFmt("{d} 0 obj\n", .{self.obj_count});
        return self.obj_count;
    }

    fn endObj(self: *PdfWriter) !void {
        try self.writeRaw("endobj\n");
    }

    fn writeRaw(self: *PdfWriter, data: []const u8) !void {
        try self.out.appendSlice(self.allocator, data);
    }

    fn writeFmt(self: *PdfWriter, comptime fmt: []const u8, args: anytype) !void {
        var buf: [1024]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, fmt, args);
        try self.writeRaw(s);
    }
};

pub fn toPdf(ed: *editor_mod.Editor, output_path: []const u8) !void {
    const cfg = ed.config;
    const font_path = cfg.fontFilePath() orelse return error.NoFontConfigured;

    var fnt = try font_mod.Font.load(ed.allocator, font_path);
    defer fnt.deinit();

    var pdf = PdfWriter.init(ed.allocator);
    defer pdf.deinit();

    // Sanitize the font name for PDF Name objects: only a conservative
    // charset survives; anything else (spaces, delimiters like '/', '(',
    // '#') would corrupt PDF object syntax.
    var pdf_font_name: [256]u8 = undefined;
    const raw_name = fnt.familyName();
    var name_len: usize = 0;
    for (raw_name) |c| {
        if (name_len >= pdf_font_name.len) break;
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or c == '.' or c == '_';
        pdf_font_name[name_len] = if (ok) c else '-';
        name_len += 1;
    }
    const font_name: []const u8 = if (name_len > 0) pdf_font_name[0..name_len] else "EmbeddedFont";

    // Layout geometry + margin sanity. Margins that leave no usable
    // content area would otherwise loop forever emitting empty pages.
    const font_size = cfg.font_size;
    // Floor the line height at the font size: a font whose vertical
    // metrics sum to zero (ascender == descender, no line gap) would
    // otherwise give a zero advance and pile every line onto one page.
    const line_height = @max(fnt.lineHeight(font_size) * 1.3, font_size);
    const page_w: f32 = 612.0;
    const page_h: f32 = 792.0;
    const margin_top = cfg.print_margin_top;
    const margin_bottom = cfg.print_margin_bottom;
    const margin_left = cfg.print_margin_left;
    const margin_right = cfg.print_margin_right;
    if (page_h - margin_top - margin_bottom < line_height or
        page_w - margin_left - margin_right < font_size)
    {
        return error.MarginsTooLarge;
    }

    // Header
    try pdf.writeRaw("%PDF-1.4\n%\xc3\xa4\xc3\xbc\xc3\xb6\xc3\x9f\n");

    // Obj 1: Catalog
    _ = try pdf.beginObj();
    try pdf.writeRaw("<< /Type /Catalog /Pages 2 0 R >>\n");
    try pdf.endObj();

    // Reserve obj 2 for Pages — written at the end once we know the page list.
    // Just increment the counter and add a placeholder offset.
    pdf.obj_count += 1;
    try pdf.offsets.append(pdf.allocator, 0); // will be overwritten

    // Obj 3: FontDescriptor
    _ = try pdf.beginObj();
    const scale = @as(f32, 1000.0) / @as(f32, @floatFromInt(fnt.units_per_em));
    try pdf.writeRaw("<< /Type /FontDescriptor\n");
    try pdf.writeFmt("/FontName /{s}\n", .{font_name});
    // PDF FontDescriptor flags: bit 1 (0x01) FixedPitch — set only for
    // monospaced fonts per the parsed `post` table — plus bit 3 (0x04)
    // Symbolic, which is correct for Identity-H embedding. (The old
    // hardcoded 37 also set the mutually-exclusive Nonsymbolic bit and
    // asserted FixedPitch for every font.)
    const flags: u32 = 0x04 | @as(u32, if (fnt.is_fixed_pitch) 0x01 else 0);
    try pdf.writeFmt("/Flags {d}\n", .{flags});
    try pdf.writeFmt("/FontBBox [{d} {d} {d} {d}]\n", .{
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.x_min)) * scale)),
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.y_min)) * scale)),
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.x_max)) * scale)),
        @as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.y_max)) * scale)),
    });
    try pdf.writeRaw("/ItalicAngle 0\n");
    try pdf.writeFmt("/Ascent {d}\n", .{@as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.ascender)) * scale))});
    try pdf.writeFmt("/Descent {d}\n", .{@as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.descender)) * scale))});
    try pdf.writeFmt("/CapHeight {d}\n", .{@as(i32, @intFromFloat(@as(f32, @floatFromInt(fnt.cap_height)) * scale))});
    try pdf.writeRaw("/StemV 80\n");
    if (fnt.is_otf) {
        try pdf.writeRaw("/FontFile3 4 0 R\n");
    } else {
        try pdf.writeRaw("/FontFile2 4 0 R\n");
    }
    try pdf.writeRaw(">>\n");
    try pdf.endObj();

    // Obj 4: Font file stream
    _ = try pdf.beginObj();
    try pdf.writeFmt("<< /Length {d}", .{fnt.data.len});
    if (fnt.is_otf) {
        try pdf.writeRaw(" /Subtype /OpenType");
    }
    try pdf.writeRaw(" >>\nstream\n");
    try pdf.writeRaw(fnt.data);
    try pdf.writeRaw("\nendstream\n");
    try pdf.endObj();

    // Obj 5: CIDFont with a real /W widths array. Relying on /DW alone
    // mis-spaced every proportional font (and /DW came from glyph 0,
    // the .notdef width).
    _ = try pdf.beginObj();
    try pdf.writeRaw("<< /Type /Font\n");
    if (fnt.is_otf) {
        try pdf.writeRaw("/Subtype /CIDFontType0\n");
    } else {
        try pdf.writeRaw("/Subtype /CIDFontType2\n");
    }
    try pdf.writeFmt("/BaseFont /{s}\n", .{font_name});
    try pdf.writeRaw("/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>\n");
    try pdf.writeRaw("/FontDescriptor 3 0 R\n");
    try pdf.writeFmt("/DW {d}\n", .{@as(i32, @intFromFloat(fnt.charWidth(' ', 1000.0)))});
    if (fnt.glyph_widths.len > 0) {
        try pdf.writeRaw("/W [ ");
        var g: usize = 0;
        while (g < fnt.glyph_widths.len) {
            const w = fnt.glyph_widths[g];
            var e = g;
            while (e + 1 < fnt.glyph_widths.len and fnt.glyph_widths[e + 1] == w) e += 1;
            try pdf.writeFmt("{d} {d} {d} ", .{
                g,
                e,
                @as(i32, @intFromFloat(@as(f32, @floatFromInt(w)) * scale)),
            });
            g = e + 1;
        }
        try pdf.writeRaw("]\n");
    }
    try pdf.writeRaw(">>\n");
    try pdf.endObj();

    // Obj 6: ToUnicode CMap. Built from the font's actual glyph→Unicode
    // reverse mapping so text extraction / copy-paste from the PDF
    // yields real characters (the old identity map produced garbage).
    _ = try pdf.beginObj();
    {
        var cmap_body: std.ArrayList(u8) = .empty;
        defer cmap_body.deinit(ed.allocator);

        try cmap_body.appendSlice(ed.allocator, "/CIDInit /ProcSet findresource begin\n" ++
            "12 dict begin\n" ++
            "begincmap\n" ++
            "/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> def\n" ++
            "/CMapName /Adobe-Identity-UCS def\n" ++
            "/CMapType 2 def\n" ++
            "1 begincodespacerange\n" ++
            "<0000> <FFFF>\n" ++
            "endcodespacerange\n");

        if (fnt.num_glyphs > 0 and fnt.cmap.len == 65536) {
            const rev = try ed.allocator.alloc(u21, fnt.num_glyphs);
            defer ed.allocator.free(rev);
            @memset(rev, 0);
            for (fnt.cmap, 0..) |gid, cp| {
                if (gid != 0 and gid < rev.len and rev[gid] == 0) rev[gid] = @intCast(cp);
            }

            // Gather mapped glyphs, then emit bfchar blocks of at most
            // 100 entries (spec limit), each declaring its exact count.
            var mapped: std.ArrayList(u16) = .empty;
            defer mapped.deinit(ed.allocator);
            for (rev, 0..) |cp, gid| {
                if (cp != 0) try mapped.append(ed.allocator, @intCast(gid));
            }

            var fmt_buf: [32]u8 = undefined;
            var idx: usize = 0;
            while (idx < mapped.items.len) {
                const chunk = @min(@as(usize, 100), mapped.items.len - idx);
                const hdr = try std.fmt.bufPrint(&fmt_buf, "{d} beginbfchar\n", .{chunk});
                try cmap_body.appendSlice(ed.allocator, hdr);
                for (mapped.items[idx .. idx + chunk]) |gid| {
                    const s = try std.fmt.bufPrint(&fmt_buf, "<{X:0>4}> <{X:0>4}>\n", .{ gid, rev[gid] });
                    try cmap_body.appendSlice(ed.allocator, s);
                }
                try cmap_body.appendSlice(ed.allocator, "endbfchar\n");
                idx += chunk;
            }
        }

        try cmap_body.appendSlice(ed.allocator, "endcmap\n" ++
            "CMapName currentdict /CMap defineresource pop\n" ++
            "end\n" ++
            "end\n");

        try pdf.writeFmt("<< /Length {d} >>\nstream\n", .{cmap_body.items.len});
        try pdf.writeRaw(cmap_body.items);
        try pdf.writeRaw("\nendstream\n");
    }
    try pdf.endObj();

    // Obj 7: Type0 font
    _ = try pdf.beginObj();
    try pdf.writeRaw("<< /Type /Font /Subtype /Type0\n");
    try pdf.writeFmt("/BaseFont /{s}\n", .{font_name});
    try pdf.writeRaw("/Encoding /Identity-H\n");
    try pdf.writeRaw("/DescendantFonts [5 0 R]\n");
    try pdf.writeRaw("/ToUnicode 6 0 R\n");
    try pdf.writeRaw(">>\n");
    try pdf.endObj();

    // Generate pages
    var page_obj_ids: std.ArrayList(usize) = .empty;
    defer page_obj_ids.deinit(ed.allocator);

    // Content width in points. The continuation indent is computed
    // per line inside the page loop (mirrors the TUI's wrap_indent).
    const space_w: f32 = @max(fnt.charWidth(' ', font_size), font_size * 0.25);
    const content_w: f32 = @max(page_w - margin_left - margin_right, space_w);
    const tw = ed.effectiveTabWidth();
    const pt = config_mod.print_theme;

    // Header text: basename of the file, page number on the right.
    const full_name = ed.getFilename();
    const header_name = if (std.mem.lastIndexOfScalar(u8, full_name, '/')) |s|
        full_name[s + 1 ..]
    else
        full_name;
    const header_size = font_size * 0.8;
    // Draw headers only when the top margin has room for one.
    const draw_header = margin_top >= line_height * 1.8;

    var y: f32 = page_h - margin_top;
    var page_lines: std.ArrayList(u8) = .empty;
    defer page_lines.deinit(ed.allocator);

    // Tokenization state carried across the whole document. Tokens for
    // the current line are cached so a line resuming on the next page
    // isn't tokenized twice (which would advance the state twice).
    var tok_buf: [256]syntax_mod.Token = undefined;
    var tokens: []syntax_mod.Token = &.{};
    var tokens_line: ?usize = null;
    var syn_state: syntax_mod.State = .normal;

    const total_lines = ed.buf.lineCount();
    var line_num: usize = 0;
    var sub_start_idx: usize = 0; // resume index when a line wraps across a page
    var page_num: usize = 1;

    while (line_num < total_lines) {
        // Start a new page content stream
        page_lines.clearRetainingCapacity();
        y = page_h - margin_top;

        // Header (its own BT/ET block, in the line-number gray).
        if (draw_header) {
            const header_y = page_h - margin_top + line_height;
            try appendFmt(&page_lines, ed.allocator, "BT\n/F1 {d:.1} Tf\n", .{header_size});
            try writeColor(&page_lines, ed.allocator, pt.line_number);
            try page_lines.appendSlice(ed.allocator, " rg\n");
            try appendFmt(&page_lines, ed.allocator, "{d:.1} {d:.1} Td\n", .{ margin_left, header_y });
            try page_lines.appendSlice(ed.allocator, "<");
            var hdr_visual: usize = 0;
            try encodeGlyphs(&page_lines, ed.allocator, &fnt, header_name, tw, &hdr_visual);
            try page_lines.appendSlice(ed.allocator, "> Tj\nET\n");

            var pg_buf: [32]u8 = undefined;
            const pg_str = try std.fmt.bufPrint(&pg_buf, "page {d}", .{page_num});
            const pg_w = fnt.stringWidth(pg_str, header_size);
            try appendFmt(&page_lines, ed.allocator, "BT\n/F1 {d:.1} Tf\n", .{header_size});
            try appendFmt(&page_lines, ed.allocator, "{d:.1} {d:.1} Td\n", .{ page_w - margin_right - pg_w, header_y });
            try page_lines.appendSlice(ed.allocator, "<");
            var pg_visual: usize = 0;
            try encodeGlyphs(&page_lines, ed.allocator, &fnt, pg_str, tw, &pg_visual);
            try page_lines.appendSlice(ed.allocator, "> Tj\nET\n");
        }

        // Content
        try appendFmt(&page_lines, ed.allocator, "BT\n/F1 {d:.1} Tf\n", .{font_size});
        try appendFmt(&page_lines, ed.allocator, "{d:.1} {d:.1} Td\n", .{ margin_left, y });

        try writeColor(&page_lines, ed.allocator, pt.fg);
        try page_lines.appendSlice(ed.allocator, " rg\n");
        var last_color: config_mod.Color = pt.fg;

        // Track the x origin of the current line matrix so we can compute
        // the relative dx for the next Td when indenting continuations.
        var last_origin_x: f32 = margin_left;

        while (line_num < total_lines and y > margin_bottom) {
            const line_info = ed.buf.getLine(line_num) orelse {
                line_num += 1;
                sub_start_idx = 0;
                continue;
            };
            var line_tmp: [max_line_bytes]u8 = undefined;
            const line_data = ed.buf.contiguousSlice(line_info.start, @min(line_info.len, max_line_bytes), &line_tmp);

            // Tokenize once per buffer line, carrying multi-line state.
            if (tokens_line != line_num) {
                tokens = if (ed.language) |lang|
                    syntax_mod.tokenizeLine(lang, line_data, &syn_state, &tok_buf)
                else
                    tok_buf[0..0];
                tokens_line = line_num;
            }

            // Per-line continuation indent (points), mirroring the TUI's
            // wrap_indent option — a flat 2 columns by default, or hanging
            // under the line's own leading whitespace when enabled. Capped
            // to half the page content width so a wide-terminal indent
            // cap (continuationIndentCols keys off the TUI's visible_cols)
            // can't push continuation text off the right page edge.
            const raw_cont_pts: f32 = space_w * @as(f32, @floatFromInt(ed.continuationIndentCols(line_num)));
            const line_cont_pts: f32 = @min(raw_cont_pts, content_w / 2.0);
            const line_cont_w: f32 = @max(content_w - line_cont_pts, space_w);

            var breaks: [MAX_WRAP_BREAKS]usize = undefined;
            const break_count = computePdfWrapBreaks(&fnt, font_size, line_data, content_w, line_cont_w, tw, &breaks);

            var si: usize = sub_start_idx;
            while (si < break_count and y > margin_bottom) : (si += 1) {
                const sub_start = breaks[si];
                const sub_end = @min(if (si + 1 < break_count) breaks[si + 1] else line_data.len, line_data.len);

                const target_x: f32 = if (si == 0) margin_left else margin_left + line_cont_pts;
                const dx = target_x - last_origin_x;
                try appendFmt(&page_lines, ed.allocator, "{d:.2} {d:.2} Td\n", .{ dx, -line_height });
                last_origin_x = target_x;

                // Visual column at the start of this sub-line, so tab
                // stops keep their document-relative alignment.
                var visual_col: usize = visualColAt(line_data, sub_start, tw);

                // Emit color-run chunks: consecutive bytes sharing a
                // token color become one hex string.
                var bi: usize = sub_start;
                while (bi < sub_end) {
                    const color = printTokenColor(tokens, bi, &pt);
                    var run_end = bi;
                    while (run_end < sub_end and
                        colorPtrEq(printTokenColor(tokens, run_end, &pt), color)) run_end += 1;

                    if (!colorPtrEq(color, last_color)) {
                        try writeColor(&page_lines, ed.allocator, color);
                        try page_lines.appendSlice(ed.allocator, " rg\n");
                        last_color = color;
                    }
                    try page_lines.appendSlice(ed.allocator, "<");
                    try encodeGlyphs(&page_lines, ed.allocator, &fnt, line_data[bi..run_end], tw, &visual_col);
                    try page_lines.appendSlice(ed.allocator, "> Tj\n");
                    bi = run_end;
                }
                // Blank sub-lines draw nothing — the Td above already
                // advanced the baseline.

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

        try page_lines.appendSlice(ed.allocator, "ET\n");

        // Content stream object
        const content_obj = try pdf.beginObj();
        try pdf.writeFmt("<< /Length {d} >>\nstream\n", .{page_lines.items.len});
        try pdf.writeRaw(page_lines.items);
        try pdf.writeRaw("\nendstream\n");
        try pdf.endObj();

        // Page object
        const page_obj = try pdf.beginObj();
        try pdf.writeRaw("<< /Type /Page /Parent 2 0 R\n");
        try pdf.writeFmt("/MediaBox [0 0 {d:.0} {d:.0}]\n", .{ page_w, page_h });
        try pdf.writeFmt("/Contents {d} 0 R\n", .{content_obj});
        try pdf.writeRaw("/Resources << /Font << /F1 7 0 R >> >>\n");
        try pdf.writeRaw(">>\n");
        try pdf.endObj();

        try page_obj_ids.append(ed.allocator, page_obj);
        page_num += 1;
    }

    // If no pages were generated, create one empty page
    if (page_obj_ids.items.len == 0) {
        const content_obj = try pdf.beginObj();
        try pdf.writeRaw("<< /Length 0 >>\nstream\n\nendstream\n");
        try pdf.endObj();

        const page_obj = try pdf.beginObj();
        try pdf.writeRaw("<< /Type /Page /Parent 2 0 R\n");
        try pdf.writeFmt("/MediaBox [0 0 {d:.0} {d:.0}]\n", .{ page_w, page_h });
        try pdf.writeFmt("/Contents {d} 0 R\n", .{content_obj});
        try pdf.writeRaw("/Resources << /Font << /F1 7 0 R >> >>\n");
        try pdf.writeRaw(">>\n");
        try pdf.endObj();

        try page_obj_ids.append(ed.allocator, page_obj);
    }

    // Write Pages object (obj 2) — now that we know the page list
    pdf.offsets.items[1] = pdf.out.items.len; // obj 2 is at offsets index 1
    try pdf.writeFmt("2 0 obj\n<< /Type /Pages /Kids [", .{});
    for (page_obj_ids.items) |pid| {
        try pdf.writeFmt("{d} 0 R ", .{pid});
    }
    try pdf.writeFmt("] /Count {d} >>\nendobj\n", .{page_obj_ids.items.len});

    // xref table
    const xref_offset = pdf.out.items.len;
    try pdf.writeRaw("xref\n");
    try pdf.writeFmt("0 {d}\n", .{pdf.obj_count + 1});
    try pdf.writeRaw("0000000000 65535 f \n");
    for (pdf.offsets.items) |off| {
        try pdf.writeFmt("{d:0>10} 00000 n \n", .{off});
    }

    // Trailer
    try pdf.writeRaw("trailer\n");
    try pdf.writeFmt("<< /Size {d} /Root 1 0 R >>\n", .{pdf.obj_count + 1});
    try pdf.writeRaw("startxref\n");
    try pdf.writeFmt("{d}\n", .{xref_offset});
    try pdf.writeRaw("%%EOF\n");

    // Write to file
    const file = try fsx.createFile(output_path, .{});
    defer file.close();
    try file.writeAll(pdf.out.items);
}

/// Print-theme color for the token covering `byte_idx` (fg when no
/// token covers it).
fn printTokenColor(tokens: []const syntax_mod.Token, byte_idx: usize, pt: *const config_mod.PrintTheme) config_mod.Color {
    for (tokens) |tok| {
        if (byte_idx >= tok.start and byte_idx < tok.end) {
            return switch (tok.token_type) {
                .keyword1 => pt.keyword,
                .keyword2 => pt.typ,
                .comment => pt.comment,
                .string => pt.string,
                .number => pt.number,
                .typ => pt.typ,
                .function => pt.function,
                .operator => pt.operator,
                .preprocessor => pt.preprocessor,
                .normal => pt.fg,
            };
        }
    }
    return pt.fg;
}

fn colorPtrEq(a: config_mod.Color, b: config_mod.Color) bool {
    return switch (a) {
        .default => b == .default,
        .ansi => |va| switch (b) {
            .ansi => |vb| va == vb,
            else => false,
        },
        .rgb => |va| switch (b) {
            .rgb => |vb| va.r == vb.r and va.g == vb.g and va.b == vb.b,
            else => false,
        },
    };
}

/// Visual column of `byte_idx` within `data`, expanding tabs.
fn visualColAt(data: []const u8, byte_idx: usize, tab_width: u8) usize {
    var visual: usize = 0;
    var i: usize = 0;
    while (i < byte_idx and i < data.len) {
        const b = data[i];
        if (b == '\t') {
            visual += tab_width - (visual % tab_width);
            i += 1;
        } else if (b < 0x80) {
            visual += 1;
            i += 1;
        } else {
            const dec = nextCodepoint(data, i);
            visual += 1;
            i += dec.len;
        }
    }
    return visual;
}

fn writeColor(list: *std.ArrayList(u8), allocator: Allocator, color: config_mod.Color) !void {
    switch (color) {
        .rgb => |c| {
            var buf: [32]u8 = undefined;
            const s = try std.fmt.bufPrint(&buf, "{d:.3} {d:.3} {d:.3}", .{
                @as(f32, @floatFromInt(c.r)) / 255.0,
                @as(f32, @floatFromInt(c.g)) / 255.0,
                @as(f32, @floatFromInt(c.b)) / 255.0,
            });
            try list.appendSlice(allocator, s);
        },
        else => {
            try list.appendSlice(allocator, "0.180 0.180 0.180");
        },
    }
}

fn appendFmt(list: *std.ArrayList(u8), allocator: Allocator, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, fmt, args);
    try list.appendSlice(allocator, s);
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
    if (b0 >= 0xF0 and i + 3 < data.len) {
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

        // Forward-progress guard for runs of unbreakable codepoints wider
        // than avail. utf8Len reports the lead byte's DECLARED length,
        // which can exceed the bytes actually present (a truncated
        // multibyte sequence at end-of-line, or one split by the
        // max_line_bytes cap). Clamp to data.len so the break offset —
        // later used to slice line_data — can never point past the end.
        if (break_at <= pos) {
            const blen = @max(@as(usize, unicode.utf8Len(data[pos])), 1);
            break_at = @min(pos + blen, data.len);
        }

        breaks[count] = break_at;
        count += 1;
        pos = break_at;
    }

    return count;
}

/// Encode a byte slice as hex glyph IDs into `list`. Tabs expand to the
/// next tab stop relative to `visual_col` (which is advanced as glyphs
/// are emitted) so tab alignment survives color-run splitting. CR/LF
/// terminators (if present) are skipped.
fn encodeGlyphs(
    list: *std.ArrayList(u8),
    allocator: Allocator,
    fnt: *const font_mod.Font,
    data: []const u8,
    tab_width: u8,
    visual_col: *usize,
) !void {
    const space_gid = fnt.glyphId(' ');
    var bi: usize = 0;
    while (bi < data.len) {
        const b0 = data[bi];
        if (b0 == '\n' or b0 == '\r') {
            bi += 1;
            continue;
        }
        if (b0 == '\t') {
            const advance = tab_width - @as(u8, @intCast(visual_col.* % tab_width));
            var k: u8 = 0;
            while (k < advance) : (k += 1) {
                var hex_buf: [4]u8 = undefined;
                const s = try std.fmt.bufPrint(&hex_buf, "{X:0>4}", .{space_gid});
                try list.appendSlice(allocator, s);
            }
            visual_col.* += advance;
            bi += 1;
            continue;
        }
        const dec = nextCodepoint(data, bi);
        const gid = fnt.glyphId(dec.cp);
        var hex_buf: [4]u8 = undefined;
        const s = try std.fmt.bufPrint(&hex_buf, "{X:0>4}", .{gid});
        try list.appendSlice(allocator, s);
        visual_col.* += 1;
        bi += dec.len;
    }
}

// ── Tests ──

test "pdf writer basic" {
    var pdf = PdfWriter.init(std.testing.allocator);
    defer pdf.deinit();

    try pdf.writeRaw("%PDF-1.4\n");
    _ = try pdf.beginObj();
    try pdf.writeRaw("<< /Type /Catalog >>\n");
    try pdf.endObj();

    try std.testing.expect(pdf.out.items.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, pdf.out.items, "%PDF-1.4"));
}

test "toPdf without a configured font errors cleanly" {
    var cfg = config_mod.Config.init();
    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();
    try std.testing.expectError(error.NoFontConfigured, toPdf(&ed, "/tmp/never-written.pdf"));
}

test "encodeGlyphs expands tabs relative to the running column" {
    var widths = [_]u16{500};
    var cmap_data = [_]u16{0} ** 65536;
    cmap_data[' '] = 0;

    const fnt = font_mod.Font{
        .allocator = std.testing.allocator,
        .units_per_em = 1000,
        .glyph_widths = &widths,
        .cmap = &cmap_data,
    };

    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(std.testing.allocator);

    // Column 2, tab width 4 → tab expands to 2 spaces, not 4.
    var visual: usize = 2;
    try encodeGlyphs(&list, std.testing.allocator, &fnt, "\t", 4, &visual);
    try std.testing.expectEqual(@as(usize, 4), visual);
    try std.testing.expectEqual(@as(usize, 8), list.items.len); // two 4-hex glyphs
}

test "computePdfWrapBreaks never overshoots a truncated multibyte tail" {
    // A line ending in a lone 4-byte lead (0xF0) with no continuation
    // bytes. The forward-progress guard trusts utf8Len (=4), so without
    // the data.len clamp break_at would be pos+4 > data.len and the
    // export slice would panic. Every break must stay within bounds.
    var widths = [_]u16{5000}; // huge advance so any glyph exceeds avail
    var cmap = [_]u16{0} ** 65536;
    cmap[0xF0] = 0; // maps to notdef (width via glyph 0)

    const fnt = font_mod.Font{
        .allocator = std.testing.allocator,
        .units_per_em = 1000,
        .glyph_widths = &widths,
        .cmap = &cmap,
    };

    const data = [_]u8{ 'a', 'b', 0xF0 }; // truncated lead at the end
    var breaks: [MAX_WRAP_BREAKS]usize = undefined;
    // Tiny available width forces the per-glyph forward-progress guard.
    const count = computePdfWrapBreaks(&fnt, 10.0, &data, 1.0, 1.0, 4, &breaks);
    var k: usize = 0;
    while (k < count) : (k += 1) {
        try std.testing.expect(breaks[k] <= data.len);
    }
}
