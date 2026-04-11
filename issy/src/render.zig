//! Screen rendering engine.
//!
//! Maintains a cell grid representing the terminal screen. Computes diffs
//! between frames and emits minimal terminal escape sequences. Draws the
//! editor content area, line numbers, status line, and prompts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const term = @import("term.zig");
const editor_mod = @import("editor.zig");
const config_mod = @import("config.zig");
const syntax_mod = @import("syntax.zig");

pub const Color = term.Color;

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    underline: bool = false,
};

pub const Renderer = struct {
    current: []Cell,
    previous: []Cell,
    rows: u16,
    cols: u16,
    allocator: Allocator,
    syntax_states: []syntax_mod.State,

    pub fn init(allocator: Allocator, rows: u16, cols: u16) !Renderer {
        const size = @as(usize, rows) * @as(usize, cols);
        const current = try allocator.alloc(Cell, size);
        @memset(current, Cell{});
        const previous = try allocator.alloc(Cell, size);
        @memset(previous, .{ .char = 0 }); // Force full redraw on first frame
        const states = try allocator.alloc(syntax_mod.State, rows);
        @memset(states, .normal);

        return .{
            .current = current,
            .previous = previous,
            .rows = rows,
            .cols = cols,
            .allocator = allocator,
            .syntax_states = states,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.current);
        self.allocator.free(self.previous);
        self.allocator.free(self.syntax_states);
    }

    pub fn resize(self: *Renderer, rows: u16, cols: u16) !void {
        self.allocator.free(self.current);
        self.allocator.free(self.previous);
        self.allocator.free(self.syntax_states);

        const size = @as(usize, rows) * @as(usize, cols);
        self.current = try self.allocator.alloc(Cell, size);
        @memset(self.current, Cell{});
        self.previous = try self.allocator.alloc(Cell, size);
        @memset(self.previous, .{ .char = 0 });
        self.syntax_states = try self.allocator.alloc(syntax_mod.State, rows);
        @memset(self.syntax_states, .normal);
        self.rows = rows;
        self.cols = cols;
    }

    fn cellAt(self: *Renderer, row: u16, col: u16) *Cell {
        return &self.current[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
    }

    fn prevAt(self: *Renderer, row: u16, col: u16) *Cell {
        return &self.previous[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
    }

    pub fn drawFrame(self: *Renderer, ed: *editor_mod.Editor) !void {
        const theme = &ed.config.theme;

        // 1. Clear all cells to bg
        for (self.current) |*cell| {
            cell.* = .{ .char = ' ', .fg = theme.fg, .bg = theme.bg };
        }

        // 2. Compute layout
        const left_pad = ed.config.left_padding;
        const gutter_width = ed.gutterWidth();
        const code_start: u16 = gutter_width;
        const right_margin = ed.config.right_margin;
        const code_end: u16 = if (right_margin > 0)
            @intCast(@min(@as(u32, right_margin) + code_start, self.cols))
        else
            self.cols;

        const status_row = if (self.rows > 0) self.rows - 1 else 0;
        const content_rows: u16 = if (self.rows > 1) self.rows - 1 else 1;
        const wrap_enabled = ed.config.word_wrap;
        const wrap_width: usize = if (code_end > code_start) @as(usize, code_end - code_start) else 1;
        const cont_indent: u16 = if (wrap_enabled) 2 else 0;

        // Track syntax state
        var syn_state: syntax_mod.State = .normal;

        // 3. Render visible lines
        var screen_row: u16 = 0;
        var file_line: usize = ed.scroll_top;

        while (screen_row < content_rows and file_line < ed.buf.lineCount()) {
            // Get line data
            const line_info = ed.buf.getLine(file_line) orelse {
                file_line += 1;
                continue;
            };
            var line_tmp: [8192]u8 = undefined;
            const line_data = ed.buf.contiguousSlice(line_info.start, @min(line_info.len, 8192), &line_tmp);

            // Tokenize
            var token_buf: [256]syntax_mod.Token = undefined;
            var tokens: []syntax_mod.Token = &.{};
            if (ed.language) |lang| {
                tokens = syntax_mod.tokenizeLine(lang, line_data, &syn_state, &token_buf);
            }

            // Determine wrap segments for this line
            const is_cursor_line = (file_line == ed.cursor.line);

            // Render the line across one or more screen rows
            var byte_idx: usize = 0;
            var buf_col: usize = 0; // column in the buffer (character index)
            var visual_sub_line: usize = 0;

            while (screen_row < content_rows) {
                const is_first_visual = (visual_sub_line == 0);
                const this_indent: u16 = if (is_first_visual) 0 else cont_indent;
                const avail_cols: usize = if (wrap_width > this_indent) wrap_width - this_indent else 1;

                // Cursor line highlight (full width) — all visual sub-lines of the cursor line
                if (ed.config.cursor_line_bg and is_cursor_line) {
                    var c: u16 = 0;
                    while (c < self.cols) : (c += 1) {
                        self.cellAt(screen_row, c).bg = theme.cursor_line_bg;
                    }
                }

                // Line numbers — only on first visual sub-line
                if (is_first_visual and ed.config.line_numbers) {
                    const line_num = file_line + 1;
                    var num_buf: [16]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "";
                    const num_color = if (is_cursor_line) theme.line_number_active else theme.line_number;

                    const digits = gutter_width - ed.config.left_padding - ed.config.gutter_padding;
                    if (num_str.len <= digits) {
                        const start_col = left_pad + digits - @as(u16, @intCast(num_str.len));
                        for (num_str, 0..) |ch, i| {
                            const scol = start_col + @as(u16, @intCast(i));
                            if (scol < self.cols) {
                                const cell = self.cellAt(screen_row, scol);
                                cell.char = ch;
                                cell.fg = num_color;
                            }
                        }
                    }
                }

                // Render characters for this visual sub-line
                var col: u16 = code_start + this_indent;
                var chars_on_row: usize = 0;
                const row_start_buf_col = buf_col;

                while (byte_idx < line_data.len and chars_on_row < avail_cols) {
                    const ch = line_data[byte_idx];
                    if (ch == '\n') break;

                    // In non-wrap mode, skip chars before scroll_left
                    if (!wrap_enabled and buf_col < ed.scroll_left) {
                        if (ch == '\t') {
                            const tw = ed.effectiveTabWidth();
                            buf_col += tw - (buf_col % tw);
                        } else {
                            buf_col += 1;
                        }
                        byte_idx += 1;
                        continue;
                    }

                    if (ch == '\t') {
                        const tw = ed.effectiveTabWidth();
                        const spaces = tw - (buf_col % tw);
                        var s: usize = 0;
                        while (s < spaces and chars_on_row < avail_cols and col < code_end) : (s += 1) {
                            self.cellAt(screen_row, col).char = ' ';
                            col += 1;
                            chars_on_row += 1;
                        }
                        buf_col += spaces;
                    } else if (ch >= 0x20 and ch < 0x7f) {
                        if (col < code_end) {
                            const cell = self.cellAt(screen_row, col);
                            cell.char = ch;
                            cell.fg = tokenColor(tokens, byte_idx, theme);
                            col += 1;
                        }
                        chars_on_row += 1;
                        buf_col += 1;
                    } else {
                        if (col < code_end) {
                            const cell = self.cellAt(screen_row, col);
                            cell.char = if (ch < 0x20) '.' else ch;
                            cell.fg = tokenColor(tokens, byte_idx, theme);
                            col += 1;
                        }
                        chars_on_row += 1;
                        buf_col += 1;
                    }

                    byte_idx += 1;
                }

                // Bracket match highlight
                if (ed.matching_bracket_pos) |bp| {
                    if (bp.line == file_line and bp.col >= row_start_buf_col and bp.col < buf_col) {
                        const offset = bp.col - row_start_buf_col;
                        const bracket_screen_col = code_start + this_indent + @as(u16, @intCast(@min(offset, std.math.maxInt(u16))));
                        if (bracket_screen_col < code_end) {
                            self.cellAt(screen_row, bracket_screen_col).bg = theme.selection;
                        }
                    }
                }

                // Trailing whitespace highlight (only on last visual sub-line of the buffer line)
                const at_line_end = (byte_idx >= line_data.len or (byte_idx < line_data.len and line_data[byte_idx] == '\n'));
                if (at_line_end and ed.config.trailing_whitespace and line_data.len > 0) {
                    const stripped = std.mem.trimRight(u8, line_data, " \t\n\r");
                    if (stripped.len > 0 and stripped.len < line_data.len) {
                        // Highlight trailing whitespace cells on this row
                        if (stripped.len >= row_start_buf_col) {
                            const tw_start_offset = stripped.len - row_start_buf_col;
                            var tw_col = code_start + this_indent + @as(u16, @intCast(@min(tw_start_offset, std.math.maxInt(u16))));
                            while (tw_col < col and tw_col < code_end) : (tw_col += 1) {
                                self.cellAt(screen_row, tw_col).bg = theme.trailing_ws;
                            }
                        }
                    }
                }

                // Multi-cursor rendering
                for (ed.cursors.items) |cursor| {
                    if (cursor.line == file_line and cursor.col >= row_start_buf_col and cursor.col < buf_col) {
                        const offset = cursor.col - row_start_buf_col;
                        const mc_col = code_start + this_indent + @as(u16, @intCast(@min(offset, std.math.maxInt(u16))));
                        if (mc_col < self.cols) {
                            const cell = self.cellAt(screen_row, mc_col);
                            const tmp_fg = cell.fg;
                            cell.fg = cell.bg;
                            cell.bg = tmp_fg;
                        }
                    }
                }

                screen_row += 1;
                visual_sub_line += 1;

                // If not wrapping, or we've consumed the whole line, move to next buffer line
                if (!wrap_enabled or at_line_end) break;
            }

            file_line += 1;
        }

        // 5. Status bar
        self.renderStatusBar(ed, status_row, theme);

        // 6. Prompts
        if (ed.mode != .normal) {
            self.renderPrompt(ed, status_row, theme);
        }

        // 7. Diff and flush
        try self.flushDiff(ed, code_start);
    }

    fn renderStatusBar(self: *Renderer, ed: *const editor_mod.Editor, row: u16, theme: *const config_mod.Theme) void {
        // Left: filename
        const fname = ed.getFilename();
        var col: u16 = 0;
        for (fname) |ch| {
            if (col >= self.cols) break;
            const cell = self.cellAt(row, col);
            cell.char = ch;
            cell.fg = theme.status_fg;
            col += 1;
        }
        if (ed.modified) {
            if (col + 2 < self.cols) {
                self.cellAt(row, col).char = ' ';
                self.cellAt(row, col).fg = theme.status_fg;
                col += 1;
                self.cellAt(row, col).char = '*';
                self.cellAt(row, col).fg = theme.status_fg;
                col += 1;
            }
        }

        // Right: line:col
        var pos_buf: [32]u8 = undefined;
        const pos_str = std.fmt.bufPrint(&pos_buf, "{d}:{d}", .{
            ed.cursor.line + 1,
            ed.cursor.col + 1,
        }) catch "";

        if (pos_str.len < self.cols) {
            const start = self.cols - @as(u16, @intCast(pos_str.len));
            for (pos_str, 0..) |ch, i| {
                const c = start + @as(u16, @intCast(i));
                const cell = self.cellAt(row, c);
                cell.char = ch;
                cell.fg = theme.status_fg;
            }
        }

        // Status message (if any)
        const msg = ed.getStatusMsg();
        if (msg.len > 0) {
            const msg_start = col + 2;
            var mc: u16 = msg_start;
            for (msg) |ch| {
                if (mc >= self.cols -| @as(u16, @intCast(pos_str.len)) -| 1) break;
                self.cellAt(row, mc).char = ch;
                self.cellAt(row, mc).fg = theme.status_fg;
                mc += 1;
            }
        }
    }

    fn renderPrompt(self: *Renderer, ed: *const editor_mod.Editor, row: u16, theme: *const config_mod.Theme) void {
        // Clear the status row
        var c: u16 = 0;
        while (c < self.cols) : (c += 1) {
            const cell = self.cellAt(row, c);
            cell.char = ' ';
            cell.fg = theme.fg;
            cell.bg = theme.bg;
        }

        switch (ed.mode) {
            .search => {
                const text = ed.getPromptText();
                var col: u16 = 0;
                for (text) |ch| {
                    if (col >= self.cols) break;
                    self.cellAt(row, col).char = ch;
                    self.cellAt(row, col).fg = theme.fg;
                    col += 1;
                }
            },
            .replace => {
                const search_text = ed.search_pattern[0..ed.search_len];
                const repl_text = ed.getReplaceText();
                var col: u16 = 0;

                // Search text
                const search_color = if (ed.replace_phase == .search) theme.fg else theme.status_fg;
                for (search_text) |ch| {
                    if (col >= self.cols) break;
                    self.cellAt(row, col).char = ch;
                    self.cellAt(row, col).fg = search_color;
                    col += 1;
                }
                // Separator
                const sep = " -> ";
                for (sep) |ch| {
                    if (col >= self.cols) break;
                    self.cellAt(row, col).char = ch;
                    self.cellAt(row, col).fg = theme.status_fg;
                    col += 1;
                }
                // Replacement
                const repl_color = if (ed.replace_phase == .replacement) theme.fg else theme.status_fg;
                for (repl_text) |ch| {
                    if (col >= self.cols) break;
                    self.cellAt(row, col).char = ch;
                    self.cellAt(row, col).fg = repl_color;
                    col += 1;
                }
            },
            .command => {
                const text = ed.getPromptText();
                var col: u16 = 0;
                for (text) |ch| {
                    if (col >= self.cols) break;
                    self.cellAt(row, col).char = ch;
                    self.cellAt(row, col).fg = theme.fg;
                    col += 1;
                }
            },
            .confirm => {
                const text = ed.getPromptText();
                var col: u16 = 0;
                for (text) |ch| {
                    if (col >= self.cols) break;
                    self.cellAt(row, col).char = ch;
                    self.cellAt(row, col).fg = theme.status_fg;
                    col += 1;
                }
            },
            .normal => {},
        }
    }

    fn flushDiff(self: *Renderer, ed: *editor_mod.Editor, code_start: u16) !void {
        term.hideCursor();

        var last_fg: Color = .default;
        var last_bg: Color = .default;

        var row: u16 = 0;
        while (row < self.rows) : (row += 1) {
            var col: u16 = 0;
            while (col < self.cols) : (col += 1) {
                const curr = self.cellAt(row, col);
                const prev = self.prevAt(row, col);

                if (curr.char == prev.char and
                    colorEq(curr.fg, prev.fg) and
                    colorEq(curr.bg, prev.bg) and
                    curr.bold == prev.bold and
                    curr.dim == prev.dim)
                {
                    col += 1 - 1; // no-op, just skip
                    continue;
                }

                term.moveCursor(row, col);

                if (!colorEq(curr.fg, last_fg)) {
                    term.setFg(curr.fg);
                    last_fg = curr.fg;
                }
                if (!colorEq(curr.bg, last_bg)) {
                    term.setBg(curr.bg);
                    last_bg = curr.bg;
                }

                // Encode char to UTF-8
                var enc: [4]u8 = undefined;
                const len = encodeChar(curr.char, &enc);
                term.write(enc[0..len]);
            }
        }

        // Copy current to previous
        @memcpy(self.previous, self.current);

        // Position hardware cursor
        term.resetStyle();

        if (ed.mode == .search or ed.mode == .command or ed.mode == .replace) {
            const cursor_col: u16 = switch (ed.mode) {
                .search => @intCast(@min(ed.search_len, self.cols - 1)),
                .command => @intCast(@min(ed.prompt_len, self.cols - 1)),
                .replace => blk: {
                    if (ed.replace_phase == .search) {
                        break :blk @intCast(@min(ed.search_len, self.cols - 1));
                    } else {
                        break :blk @intCast(@min(ed.search_len + 4 + ed.replace_len, self.cols - 1));
                    }
                },
                else => 0,
            };
            term.moveCursor(if (self.rows > 0) self.rows - 1 else 0, cursor_col);
        } else if (ed.config.word_wrap) {
            // Compute cursor screen position accounting for wrapping
            const wrap_w = ed.wrapWidth();
            const cont_w = if (wrap_w > 2) wrap_w - 2 else 1;

            // Count visual rows from scroll_top to cursor line
            var vis_row: u16 = 0;
            var line = ed.scroll_top;
            while (line < ed.cursor.line) : (line += 1) {
                vis_row += @intCast(@min(ed.visualLinesForBufferLine(line), self.rows));
            }

            // Add sub-line offset within cursor's buffer line
            var cur_col = ed.cursor.col;
            if (cur_col <= wrap_w) {
                // On first visual sub-line
                term.moveCursor(vis_row, code_start + @as(u16, @intCast(@min(cur_col, std.math.maxInt(u16)))));
            } else {
                // On a continuation sub-line
                cur_col -= wrap_w;
                const sub_line = 1 + cur_col / cont_w;
                const col_in_sub = cur_col % cont_w;
                vis_row += @intCast(@min(sub_line, self.rows));
                term.moveCursor(vis_row, code_start + 2 + @as(u16, @intCast(@min(col_in_sub, std.math.maxInt(u16)))));
            }
        } else {
            const cursor_row: u16 = if (ed.cursor.line >= ed.scroll_top)
                @intCast(@min(ed.cursor.line - ed.scroll_top, self.rows - 1))
            else
                0;
            const cursor_col = code_start + @as(u16, @intCast(@min(ed.cursor.col, std.math.maxInt(u16)))) -| @as(u16, @intCast(@min(ed.scroll_left, std.math.maxInt(u16))));
            term.moveCursor(cursor_row, cursor_col);
        }

        term.setCursorShape(ed.config.cursor_style);
        term.showCursor();
        try term.flush();
    }

};

fn tokenColor(tokens: []syntax_mod.Token, byte_idx: usize, theme: *const config_mod.Theme) Color {
    for (tokens) |tok| {
        if (byte_idx >= tok.start and byte_idx < tok.end) {
            return switch (tok.token_type) {
                .keyword1 => theme.keyword,
                .keyword2 => theme.typ,
                .comment => theme.comment,
                .string => theme.string,
                .number => theme.number,
                .typ => theme.typ,
                .function => theme.function,
                .operator => theme.operator,
                .preprocessor => theme.preprocessor,
                .normal => theme.fg,
            };
        }
    }
    return theme.fg;
}

fn colorEq(a: Color, b: Color) bool {
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

fn encodeChar(cp: u21, out: *[4]u8) usize {
    if (cp < 0x80) {
        out[0] = @intCast(cp);
        return 1;
    } else if (cp < 0x800) {
        out[0] = @intCast(0xC0 | (cp >> 6));
        out[1] = @intCast(0x80 | (cp & 0x3F));
        return 2;
    } else if (cp < 0x10000) {
        out[0] = @intCast(0xE0 | (cp >> 12));
        out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[2] = @intCast(0x80 | (cp & 0x3F));
        return 3;
    } else {
        out[0] = @intCast(0xF0 | (cp >> 18));
        out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
        out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
        out[3] = @intCast(0x80 | (cp & 0x3F));
        return 4;
    }
}

// ── Tests ──

test "renderer init and deinit" {
    var renderer = try Renderer.init(std.testing.allocator, 10, 40);
    defer renderer.deinit();

    try std.testing.expectEqual(@as(u16, 10), renderer.rows);
    try std.testing.expectEqual(@as(u16, 40), renderer.cols);
}

test "renderer resize" {
    var renderer = try Renderer.init(std.testing.allocator, 10, 40);
    defer renderer.deinit();

    try renderer.resize(20, 80);
    try std.testing.expectEqual(@as(u16, 20), renderer.rows);
    try std.testing.expectEqual(@as(u16, 80), renderer.cols);
}

test "cell defaults" {
    const cell = Cell{};
    try std.testing.expectEqual(@as(u21, ' '), cell.char);
    try std.testing.expectEqual(false, cell.bold);
}

test "colorEq" {
    try std.testing.expect(colorEq(.default, .default));
    try std.testing.expect(!colorEq(.default, .{ .ansi = 1 }));
    try std.testing.expect(colorEq(.{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }));
}

test "encodeChar ASCII" {
    var buf: [4]u8 = undefined;
    const len = encodeChar('A', &buf);
    try std.testing.expectEqual(@as(usize, 1), len);
    try std.testing.expectEqual(@as(u8, 'A'), buf[0]);
}
