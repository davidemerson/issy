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
        const right_margin = ed.config.right_margin;

        // Centering: if terminal is wider than 130 cols, center the active area
        const active_width: u16 = if (right_margin > 0)
            @intCast(@min(@as(u32, right_margin) + gutter_width, self.cols))
        else
            self.cols;
        const center_offset: u16 = if (self.cols > 130 and active_width < self.cols)
            (self.cols - active_width) / 2
        else
            0;

        const code_start: u16 = gutter_width + center_offset;
        const code_end: u16 = if (right_margin > 0)
            @intCast(@min(@as(u32, right_margin) + code_start, self.cols))
        else
            self.cols;

        const status_row = if (self.rows > 0) self.rows - 1 else 0;
        const content_rows: u16 = if (self.rows > 1) self.rows - 1 else 1;
        const wrap_enabled = ed.config.word_wrap;
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

            // Compute wrap break points for this line
            const is_cursor_line = (file_line == ed.cursor.line);
            var wrap_breaks: [editor_mod.Editor.MAX_WRAP_BREAKS]usize = undefined;
            const wrap_break_count = ed.computeWrapBreaks(file_line, &wrap_breaks);

            // Render the line across one or more screen rows
            var byte_idx: usize = 0;
            var buf_col: usize = 0;
            var visual_sub_line: usize = 0;

            while (screen_row < content_rows) {
                const is_first_visual = (visual_sub_line == 0);
                const this_indent: u16 = if (is_first_visual) 0 else cont_indent;

                // Determine how many buffer columns this sub-line spans
                const sub_end_col: usize = if (visual_sub_line + 1 < wrap_break_count)
                    wrap_breaks[visual_sub_line + 1]
                else
                    line_data.len; // rest of line

                // Cursor line highlight (full width)
                if (ed.config.cursor_line_bg and is_cursor_line) {
                    var c: u16 = 0;
                    while (c < self.cols) : (c += 1) {
                        self.cellAt(screen_row, c).bg = theme.cursor_line_bg;
                    }
                }

                // Line numbers on first visual sub-line, wrap indicator on continuations
                if (is_first_visual and ed.config.line_numbers) {
                    const line_num = file_line + 1;
                    var num_buf: [16]u8 = undefined;
                    const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "";
                    const num_color = if (is_cursor_line) theme.line_number_active else theme.line_number;

                    const digits = gutter_width - ed.config.left_padding - ed.config.gutter_padding;
                    if (num_str.len <= digits) {
                        const start_col = center_offset + left_pad + digits - @as(u16, @intCast(num_str.len));
                        for (num_str, 0..) |ch, i| {
                            const scol = start_col + @as(u16, @intCast(i));
                            if (scol < self.cols) {
                                const cell = self.cellAt(screen_row, scol);
                                cell.char = ch;
                                cell.fg = num_color;
                            }
                        }
                    }
                } else if (!is_first_visual and wrap_enabled) {
                    // Continuation line: show ↔ indicator in the gutter
                    const indicator_col = code_start -| 2; // just before the code area
                    if (indicator_col < self.cols) {
                        const cell = self.cellAt(screen_row, indicator_col);
                        cell.char = 0x2194; // ↔
                        cell.fg = theme.wrap_indicator;
                    }
                }

                // Render characters for this visual sub-line.
                //
                // The termination check compares `byte_idx` against
                // `sub_end_col` because both are byte offsets: sub_end_col
                // comes from editor.computeWrapBreaks (byte positions)
                // or from line_data.len. Do NOT use buf_col here —
                // that's a visual column and on tab-bearing lines it
                // runs ahead of byte_idx, causing the loop to exit
                // early. When that happened the outer sub-line loop
                // kept advancing visual_sub_line without drawing
                // anything, at_line_end stayed false, and the whole
                // screen filled with empty wrap-continuation rows for
                // a single buffer line.
                var col: u16 = code_start + this_indent;
                const row_start_buf_col = buf_col;

                while (byte_idx < line_data.len and byte_idx < sub_end_col) {
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
                        while (s < spaces and col < code_end) : (s += 1) {
                            self.cellAt(screen_row, col).char = ' ';
                            col += 1;
                        }
                        buf_col += spaces;
                    } else if (ch >= 0x20 and ch < 0x7f) {
                        if (col < code_end) {
                            const cell = self.cellAt(screen_row, col);
                            cell.char = ch;
                            cell.fg = tokenColor(tokens, byte_idx, theme);
                            col += 1;
                        }
                        buf_col += 1;
                    } else {
                        if (col < code_end) {
                            const cell = self.cellAt(screen_row, col);
                            cell.char = if (ch < 0x20) '.' else ch;
                            cell.fg = tokenColor(tokens, byte_idx, theme);
                            col += 1;
                        }
                        buf_col += 1;
                    }

                    byte_idx += 1;
                }

                // Bracket match highlight. bp.col is a byte offset but
                // row_start_buf_col / buf_col are visual columns (tab
                // expansion runs buf_col ahead of byte_idx), so convert
                // through byteColToVisualCol before comparing.
                if (ed.matching_bracket_pos) |bp| {
                    if (bp.line == file_line) {
                        const bp_visual = ed.byteColToVisualCol(file_line, bp.col);
                        if (bp_visual >= row_start_buf_col and bp_visual < buf_col) {
                            const offset = bp_visual - row_start_buf_col;
                            const bracket_screen_col = code_start + this_indent + @as(u16, @intCast(@min(offset, std.math.maxInt(u16))));
                            if (bracket_screen_col < code_end) {
                                self.cellAt(screen_row, bracket_screen_col).bg = theme.selection;
                            }
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

                // Multi-cursor rendering. Same tab-expansion caveat as
                // the bracket-match block above: cursor.col is a byte
                // offset, the buf_col window is visual.
                for (ed.cursors.items) |cursor| {
                    if (cursor.line == file_line) {
                        const cursor_visual = ed.byteColToVisualCol(file_line, cursor.col);
                        if (cursor_visual >= row_start_buf_col and cursor_visual < buf_col) {
                            const offset = cursor_visual - row_start_buf_col;
                            const mc_col = code_start + this_indent + @as(u16, @intCast(@min(offset, std.math.maxInt(u16))));
                            if (mc_col < self.cols) {
                                const cell = self.cellAt(screen_row, mc_col);
                                const tmp_fg = cell.fg;
                                cell.fg = cell.bg;
                                cell.bg = tmp_fg;
                            }
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
        self.renderStatusBar(ed, status_row, theme, center_offset, code_end);

        // 6. Prompts
        if (ed.mode != .normal and ed.mode != .help) {
            self.renderPrompt(ed, status_row, theme, center_offset);
        }

        // 6b. Help overlay
        if (ed.mode == .help) {
            self.renderHelpOverlay(theme);
        }

        // 7. Diff and flush
        try self.flushDiff(ed, code_start, center_offset);
    }

    fn renderStatusBar(self: *Renderer, ed: *const editor_mod.Editor, row: u16, theme: *const config_mod.Theme, center_offset: u16, code_end: u16) void {
        // Left: filename (aligned with code area)
        const fname = ed.getFilename();
        var col: u16 = center_offset;
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

        // Right-align line:col at the code_end boundary
        const right_edge = code_end;
        if (pos_str.len < right_edge) {
            const start = right_edge - @as(u16, @intCast(pos_str.len));
            for (pos_str, 0..) |ch, i| {
                const c = start + @as(u16, @intCast(i));
                if (c < self.cols) {
                    const cell = self.cellAt(row, c);
                    cell.char = ch;
                    cell.fg = theme.status_fg;
                }
            }
        }

        // Status message (if any)
        const msg = ed.getStatusMsg();
        if (msg.len > 0) {
            const msg_start = col + 2;
            var mc: u16 = msg_start;
            for (msg) |ch| {
                if (mc >= right_edge -| @as(u16, @intCast(pos_str.len)) -| 1) break;
                self.cellAt(row, mc).char = ch;
                self.cellAt(row, mc).fg = theme.status_fg;
                mc += 1;
            }
        }
    }

    fn renderPrompt(self: *Renderer, ed: *const editor_mod.Editor, row: u16, theme: *const config_mod.Theme, center_offset: u16) void {
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
                var col: u16 = center_offset;
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
                var col: u16 = center_offset;

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
                // Draw completion matches above the prompt line
                if (ed.completion_match_count > 1) {
                    // Find the prefix portion (directory + typed prefix) to align filenames
                    const prompt = ed.prompt_buf[0..ed.prompt_len];
                    const last_slash = std.mem.lastIndexOfScalar(u8, prompt, '/');
                    const dir_display_len: u16 = if (last_slash) |s| @intCast(@min(s + 1, std.math.maxInt(u16))) else 0;

                    var mi: usize = 0;
                    while (mi < ed.completion_match_count) : (mi += 1) {
                        const match_row = row -| @as(u16, @intCast(ed.completion_match_count - mi));
                        if (match_row >= row) continue; // overflow

                        // Clear the row
                        var cc: u16 = 0;
                        while (cc < self.cols) : (cc += 1) {
                            const cl = self.cellAt(match_row, cc);
                            cl.char = ' ';
                            cl.fg = theme.bg;
                            cl.bg = theme.bg;
                        }

                        // Draw the match filename right-aligned to the prompt's slash position
                        const match_name = ed.completion_matches[mi][0..ed.completion_match_lens[mi]];
                        const name_start = center_offset + dir_display_len;
                        var mc: u16 = name_start;
                        for (match_name) |mch| {
                            if (mc >= self.cols) break;
                            const cl = self.cellAt(match_row, mc);
                            cl.char = mch;
                            cl.fg = theme.comment; // dim
                            mc += 1;
                        }
                    }
                }

                // Draw the prompt text
                const text = ed.prompt_buf[0..ed.prompt_len];
                var col_c: u16 = center_offset;
                for (text) |ch| {
                    if (col_c >= self.cols) break;
                    self.cellAt(row, col_c).char = ch;
                    self.cellAt(row, col_c).fg = theme.fg;
                    col_c += 1;
                }

                // Draw the completion hint (grayed out)
                if (ed.completion_hint_len > 0) {
                    const hint = ed.completion_hint[0..ed.completion_hint_len];
                    for (hint) |ch| {
                        if (col_c >= self.cols) break;
                        self.cellAt(row, col_c).char = ch;
                        self.cellAt(row, col_c).fg = theme.comment;
                        col_c += 1;
                    }
                }
            },
            .confirm => {
                const text = ed.getPromptText();
                var col: u16 = center_offset;
                for (text) |ch| {
                    if (col >= self.cols) break;
                    self.cellAt(row, col).char = ch;
                    self.cellAt(row, col).fg = theme.status_fg;
                    col += 1;
                }
            },
            .normal, .help => {},
        }
    }

    fn renderHelpOverlay(self: *Renderer, theme: *const config_mod.Theme) void {
        const lines = [_][]const u8{
            "          Keybindings",
            "",
            "  Ctrl+S   Save          Ctrl+O   Open file",
            "  Ctrl+Q   Quit          Ctrl+N   New buffer",
            "  Ctrl+W   Quit          Ctrl+R   Reload",
            "",
            "  Ctrl+Z   Undo          Ctrl+F   Search",
            "  Ctrl+Y   Redo          Ctrl+G   Find next",
            "  Ctrl+C   Copy          Ctrl+H   Replace",
            "  Ctrl+X   Cut           Ctrl+D   Multi-cursor",
            "  Ctrl+V   Paste         Ctrl+P   Print to PDF",
            "  Ctrl+A   Select all    Escape   Clear/cancel",
            "",
            "  Ctrl+/   This help     F1       This help",
            "",
            "       Press any key to dismiss",
        };

        const box_w: u16 = 49;
        const box_h: u16 = @intCast(lines.len + 2); // +2 for top/bottom border
        const start_row: u16 = if (self.rows > box_h) (self.rows - box_h) / 2 else 0;
        const start_col: u16 = if (self.cols > box_w) (self.cols - box_w) / 2 else 0;

        const box_bg = theme.cursor_line_bg;
        const dim_fg = theme.comment;
        const bright_fg = theme.fg;

        var row: u16 = start_row;
        while (row < start_row + box_h and row < self.rows) : (row += 1) {
            var col: u16 = start_col;
            while (col < start_col + box_w and col < self.cols) : (col += 1) {
                const cell = self.cellAt(row, col);
                cell.bg = box_bg;

                const line_idx = row -| start_row;
                const col_idx = col -| start_col;

                // Top/bottom border
                if (line_idx == 0 or line_idx == box_h - 1) {
                    cell.char = ' ';
                    cell.fg = dim_fg;
                } else {
                    const text_line_idx = line_idx - 1;
                    if (text_line_idx < lines.len) {
                        const text = lines[text_line_idx];
                        if (col_idx < text.len) {
                            cell.char = text[col_idx];
                            // Title and dismiss line are bright, keys are bright, descriptions dim
                            if (text_line_idx == 0 or text_line_idx == lines.len - 1) {
                                cell.fg = bright_fg;
                            } else {
                                cell.fg = bright_fg;
                            }
                        } else {
                            cell.char = ' ';
                            cell.fg = dim_fg;
                        }
                    } else {
                        cell.char = ' ';
                        cell.fg = dim_fg;
                    }
                }
            }
        }
    }

    fn flushDiff(self: *Renderer, ed: *editor_mod.Editor, code_start: u16, center_offset: u16) !void {
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

        if (ed.mode == .help) {
            // Hide cursor during help overlay
            term.hideCursor();
            try term.flush();
            return;
        }

        if (ed.mode == .search or ed.mode == .command or ed.mode == .replace) {
            const prompt_col: u16 = switch (ed.mode) {
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
            term.moveCursor(if (self.rows > 0) self.rows - 1 else 0, center_offset + prompt_col);
        } else if (ed.config.word_wrap) {
            // Count visual rows from scroll_top to cursor line
            var vis_row: u16 = 0;
            var line = ed.scroll_top;
            while (line < ed.cursor.line) : (line += 1) {
                vis_row +|= @intCast(@min(ed.visualLinesForBufferLine(line), self.rows));
            }
            // Add cursor's sub-line within its wrapped line
            const sub = ed.cursorVisualSubLine();
            vis_row +|= @intCast(@min(sub, self.rows));
            // Column within sub-line — must be in visual cols, not byte
            // cols, or the cursor drifts on tab-bearing lines.
            const col_in_sub = ed.cursorVisualColInSubLine();
            const indent: u16 = if (sub > 0) 2 else 0;
            term.moveCursor(
                @min(vis_row, self.rows -| 1),
                code_start + indent + @as(u16, @intCast(@min(col_in_sub, std.math.maxInt(u16)))),
            );
        } else {
            const cursor_row: u16 = if (ed.cursor.line >= ed.scroll_top)
                @intCast(@min(ed.cursor.line - ed.scroll_top, self.rows - 1))
            else
                0;
            const cursor_visual = ed.byteColToVisualCol(ed.cursor.line, ed.cursor.col);
            const cursor_col = code_start + @as(u16, @intCast(@min(cursor_visual, std.math.maxInt(u16)))) -| @as(u16, @intCast(@min(ed.scroll_left, std.math.maxInt(u16))));
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
