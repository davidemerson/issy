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
const unicode = @import("unicode.zig");

pub const Color = term.Color;

pub const Cell = struct {
    char: u21 = ' ',
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    underline: bool = false,
};

/// A search match's byte range, used for viewport highlighting while
/// search/replace mode is active.
const MatchRange = struct { start: usize, end: usize };

pub const Renderer = struct {
    current: []Cell,
    previous: []Cell,
    rows: u16,
    cols: u16,
    allocator: Allocator,
    /// Syntax-state cache: syn_states.items[i] is the tokenizer state at
    /// the START of buffer line i (entry 0 is always .normal). Entries
    /// [0..syn_valid) are valid; edits invalidate from the edited line
    /// via the buffer's dirty watermark. This is what makes multi-line
    /// comments and strings highlight correctly when their opening
    /// delimiter is scrolled above the viewport.
    syn_states: std.ArrayList(syntax_mod.State),
    syn_valid: usize,
    syn_lang: ?*const syntax_mod.Language,

    pub fn init(allocator: Allocator, rows: u16, cols: u16) !Renderer {
        const size = @as(usize, rows) * @as(usize, cols);
        const current = try allocator.alloc(Cell, size);
        @memset(current, Cell{});
        const previous = try allocator.alloc(Cell, size);
        @memset(previous, .{ .char = 0 }); // Force full redraw on first frame

        return .{
            .current = current,
            .previous = previous,
            .rows = rows,
            .cols = cols,
            .allocator = allocator,
            .syn_states = .{},
            .syn_valid = 0,
            .syn_lang = null,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.current);
        self.allocator.free(self.previous);
        self.syn_states.deinit(self.allocator);
    }

    pub fn resize(self: *Renderer, rows: u16, cols: u16) !void {
        self.allocator.free(self.current);
        self.allocator.free(self.previous);

        const size = @as(usize, rows) * @as(usize, cols);
        self.current = try self.allocator.alloc(Cell, size);
        @memset(self.current, Cell{});
        self.previous = try self.allocator.alloc(Cell, size);
        @memset(self.previous, .{ .char = 0 });
        self.rows = rows;
        self.cols = cols;
        // The syntax-state cache is line-indexed, not screen-indexed —
        // it survives resizes untouched.
    }

    /// Tokenizer state at the start of `target` line. Computed from the
    /// nearest cached line forward, caching every intermediate line, so
    /// scrolling costs only the newly-exposed lines and an edit costs
    /// only the lines at and below it.
    fn stateAtLine(self: *Renderer, ed: *editor_mod.Editor, target: usize) syntax_mod.State {
        const lang = ed.language orelse return .normal;
        if (self.syn_valid == 0) {
            self.syn_states.clearRetainingCapacity();
            self.syn_states.append(self.allocator, .normal) catch return .normal;
            self.syn_valid = 1;
        }
        if (target < self.syn_valid) return self.syn_states.items[target];

        var state = self.syn_states.items[self.syn_valid - 1];
        var line = self.syn_valid - 1;
        var tokens: [256]syntax_mod.Token = undefined;
        var tmp: [8192]u8 = undefined;
        while (line < target) : (line += 1) {
            const info = ed.buf.getLine(line) orelse break;
            const data = ed.buf.contiguousSlice(info.start, @min(info.len, 8192), &tmp);
            _ = syntax_mod.tokenizeLine(lang, data, &state, &tokens);
            self.cacheState(line + 1, state);
        }
        return state;
    }

    /// Record the state at the start of `line`, extending the valid
    /// prefix when the entry is contiguous with it.
    fn cacheState(self: *Renderer, line: usize, state: syntax_mod.State) void {
        if (line == self.syn_states.items.len) {
            self.syn_states.append(self.allocator, state) catch return;
        } else if (line < self.syn_states.items.len) {
            self.syn_states.items[line] = state;
        } else {
            return;
        }
        if (self.syn_valid == line) self.syn_valid = line + 1;
    }

    /// Collect search-match byte ranges that may be visible, sorted by
    /// position. Only active in search/replace mode.
    fn collectViewportMatches(self: *Renderer, ed: *editor_mod.Editor, out: *[256]MatchRange) []const MatchRange {
        if (ed.mode != .search and ed.mode != .replace) return out[0..0];
        if (ed.search_len == 0) return out[0..0];
        const pattern = ed.search_pattern[0..ed.search_len];
        const ic = ed.searchIgnoreCase();
        const first = ed.buf.getLine(ed.scroll_top) orelse return out[0..0];
        // Upper bound on bytes that can appear on screen.
        const limit = @min(ed.buf.logicalLen(), first.start + @as(usize, self.rows) * 8192);
        var pos = first.start;
        var n: usize = 0;
        while (n < out.len) {
            const p = ed.buf.find(pattern, pos, ic) orelse break;
            if (p >= limit) break;
            out[n] = .{ .start = p, .end = p + pattern.len };
            n += 1;
            pos = p + 1;
        }
        return out[0..n];
    }

    fn cellAt(self: *Renderer, row: u16, col: u16) *Cell {
        return &self.current[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
    }

    fn prevAt(self: *Renderer, row: u16, col: u16) *Cell {
        return &self.previous[@as(usize, row) * @as(usize, self.cols) + @as(usize, col)];
    }

    pub fn drawFrame(self: *Renderer, ed: *editor_mod.Editor) !void {
        const code_start, const center_offset = self.paintFrame(ed);
        try self.flushDiff(ed, code_start, center_offset);
    }

    /// Build the cell grid for one frame without flushing to the
    /// terminal. Returns `(code_start, center_offset)` for the caller
    /// (drawFrame uses these to position the hardware cursor in
    /// flushDiff). Tests use this entry point because flushDiff writes
    /// to stdout and deadlocks under the Zig test runner's listen pipe.
    pub fn paintFrame(self: *Renderer, ed: *editor_mod.Editor) struct { u16, u16 } {
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

        // Resolve the active selection once per frame. Each cell-write
        // checks `abs_byte` against this range and applies the
        // selection bg if it's inside.
        const sel_range: ?editor_mod.Editor.SelectionRange = if (ed.sel_active) ed.getSelectionRange() else null;

        // Search-match highlighting (search/replace mode only).
        var match_buf: [256]MatchRange = undefined;
        const matches = self.collectViewportMatches(ed, &match_buf);

        // Syntax-state cache maintenance: a language change resets it, an
        // edit invalidates from the edited line down.
        if (ed.language != self.syn_lang) {
            self.syn_lang = ed.language;
            self.syn_valid = 0;
        }
        if (ed.buf.takeDirtyMinPos()) |p| {
            const dirty_line = ed.buf.lineOfPos(p);
            self.syn_valid = @min(self.syn_valid, dirty_line + 1);
        }

        // Tokenizer state at the top of the viewport — carried in from
        // the cache so multi-line comments/strings opened above the
        // viewport render correctly.
        var syn_state: syntax_mod.State = self.stateAtLine(ed, ed.scroll_top);

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

            // Tokenize, and feed the resulting state (start of the next
            // line) back into the cache so scrolling down is incremental.
            var token_buf: [256]syntax_mod.Token = undefined;
            var tokens: []syntax_mod.Token = &.{};
            if (ed.language) |lang| {
                tokens = syntax_mod.tokenizeLine(lang, line_data, &syn_state, &token_buf);
                self.cacheState(file_line + 1, syn_state);
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

                    // Determine how many bytes this codepoint occupies up
                    // front so every branch advances byte_idx correctly.
                    // For ASCII (and tab) this is 1; for multi-byte UTF-8
                    // it is 2-4.
                    const cp_len: usize = if (ch < 0x80) 1 else unicode.utf8Len(ch);

                    // Selection check is computed once per character so
                    // tab-expanded space cells all inherit the same
                    // in_sel value. Live search matches highlight with
                    // the same background.
                    const abs_byte = line_info.start + byte_idx;
                    const in_sel = (if (sel_range) |sr|
                        (abs_byte >= sr.start and abs_byte < sr.start + sr.len)
                    else
                        false) or matchAt(matches, abs_byte);

                    // In non-wrap mode, skip chars before scroll_left
                    if (!wrap_enabled and buf_col < ed.scroll_left) {
                        if (ch == '\t') {
                            const tw = ed.effectiveTabWidth();
                            buf_col += tw - (buf_col % tw);
                        } else {
                            buf_col += 1;
                        }
                        byte_idx += cp_len;
                        continue;
                    }

                    if (ch == '\t') {
                        const tw = ed.effectiveTabWidth();
                        const spaces = tw - (buf_col % tw);
                        var s: usize = 0;
                        while (s < spaces and col < code_end) : (s += 1) {
                            const cell = self.cellAt(screen_row, col);
                            cell.char = ' ';
                            if (in_sel) cell.bg = theme.selection;
                            col += 1;
                        }
                        buf_col += spaces;
                    } else if (ch >= 0x20 and ch < 0x7f) {
                        if (col < code_end) {
                            const cell = self.cellAt(screen_row, col);
                            cell.char = ch;
                            cell.fg = tokenColor(tokens, byte_idx, theme);
                            if (in_sel) cell.bg = theme.selection;
                            col += 1;
                        }
                        buf_col += 1;
                    } else if (ch < 0x20) {
                        // C0 control byte — render as a placeholder dot.
                        if (col < code_end) {
                            const cell = self.cellAt(screen_row, col);
                            cell.char = '.';
                            cell.fg = tokenColor(tokens, byte_idx, theme);
                            if (in_sel) cell.bg = theme.selection;
                            col += 1;
                        }
                        buf_col += 1;
                    } else {
                        // Multi-byte UTF-8. Decode the full codepoint and
                        // store it in a single cell. Storing the raw lead
                        // byte (0xC2..0xF4) in cell.char would emit it as
                        // U+00C2..U+00F4 — that is the source of the
                        // garbled `â` glyphs the user reported.
                        const r = unicode.decode(line_data[byte_idx..]);
                        if (col < code_end) {
                            const cell = self.cellAt(screen_row, col);
                            cell.char = r.codepoint;
                            cell.fg = tokenColor(tokens, byte_idx, theme);
                            if (in_sel) cell.bg = theme.selection;
                            col += 1;
                        }
                        buf_col += 1;
                        byte_idx += r.len;
                        continue;
                    }

                    byte_idx += cp_len;
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

                // Trailing whitespace highlight (only on last visual sub-line of the buffer line).
                // Skipped when this line overlaps the active selection so
                // selection bg is not overwritten by the trailing-ws bg.
                const at_line_end = (byte_idx >= line_data.len or (byte_idx < line_data.len and line_data[byte_idx] == '\n'));
                const line_in_sel = if (sel_range) |sr| blk: {
                    const line_end = line_info.start + line_data.len;
                    const sel_end = sr.start + sr.len;
                    break :blk (sr.start < line_end and sel_end > line_info.start);
                } else false;
                if (at_line_end and ed.config.trailing_whitespace and line_data.len > 0 and !line_in_sel) {
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

        return .{ code_start, center_offset };
    }

    /// Write UTF-8 `text` into cells on `row` starting at `col`, one
    /// codepoint per cell, stopping before `max_col`. Returns the next
    /// free column. Rendering byte-per-cell garbled any non-ASCII
    /// filename, status message, or prompt text.
    fn putTextUtf8(self: *Renderer, row: u16, col: u16, text: []const u8, fg: Color, max_col: u16) u16 {
        var c = col;
        var i: usize = 0;
        const cap = @min(max_col, self.cols);
        while (i < text.len and c < cap) {
            const r = unicode.decode(text[i..]);
            const cell = self.cellAt(row, c);
            cell.char = r.codepoint;
            cell.fg = fg;
            c += 1;
            i += r.len;
        }
        return c;
    }

    fn renderStatusBar(self: *Renderer, ed: *const editor_mod.Editor, row: u16, theme: *const config_mod.Theme, center_offset: u16, code_end: u16) void {
        // Left: filename (aligned with code area)
        var col = self.putTextUtf8(row, center_offset, ed.getFilename(), theme.status_fg, self.cols);
        if (ed.modified) {
            col = self.putTextUtf8(row, col, " *", theme.status_fg, self.cols);
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
            _ = self.putTextUtf8(row, start, pos_str, theme.status_fg, self.cols);
        }

        // Status message (if any)
        const msg = ed.getStatusMsg();
        if (msg.len > 0) {
            const msg_cap = right_edge -| @as(u16, @intCast(pos_str.len)) -| 1;
            _ = self.putTextUtf8(row, col + 2, msg, theme.status_fg, msg_cap);
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
                var col = self.putTextUtf8(row, center_offset, ed.getPromptText(), theme.fg, self.cols);
                // Match counter, dim, two cells after the pattern.
                if (ed.search_len > 0) {
                    var cnt_buf: [32]u8 = undefined;
                    const cnt = std.fmt.bufPrint(&cnt_buf, "{d}/{d}", .{
                        ed.search_match_index,
                        ed.search_match_count,
                    }) catch "";
                    col = self.putTextUtf8(row, col + 2, cnt, theme.status_fg, self.cols);
                }
            },
            .replace => {
                const search_text = ed.search_pattern[0..ed.search_len];
                const repl_text = ed.getReplaceText();
                var col: u16 = center_offset;

                const search_color = if (ed.replace_phase == .search) theme.fg else theme.status_fg;
                col = self.putTextUtf8(row, col, search_text, search_color, self.cols);
                col = self.putTextUtf8(row, col, " -> ", theme.status_fg, self.cols);
                const repl_color = if (ed.replace_phase == .replacement) theme.fg else theme.status_fg;
                col = self.putTextUtf8(row, col, repl_text, repl_color, self.cols);
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
                        _ = self.putTextUtf8(match_row, name_start, match_name, theme.comment, self.cols);
                    }
                }

                // Draw the prompt text, then the completion hint (grayed out)
                const text = ed.prompt_buf[0..ed.prompt_len];
                var col_c = self.putTextUtf8(row, center_offset, text, theme.fg, self.cols);
                if (ed.completion_hint_len > 0) {
                    const hint = ed.completion_hint[0..ed.completion_hint_len];
                    col_c = self.putTextUtf8(row, col_c, hint, theme.comment, self.cols);
                }
            },
            .confirm => {
                _ = self.putTextUtf8(row, center_offset, ed.getPromptText(), theme.status_fg, self.cols);
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
            "  Ctrl+A   Select all    Ctrl+L   Go to line",
            "  Escape   Clear/cancel",
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
                    curr.dim == prev.dim and
                    curr.underline == prev.underline)
                {
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
            // Prompt text renders one cell per codepoint, so the
            // hardware cursor must count codepoints, not bytes.
            const search_cps = unicode.countCodepoints(ed.search_pattern[0..ed.search_len]);
            const prompt_col: u16 = switch (ed.mode) {
                .search => @intCast(@min(search_cps, self.cols - 1)),
                .command => @intCast(@min(unicode.countCodepoints(ed.prompt_buf[0..ed.prompt_len]), self.cols - 1)),
                .replace => blk: {
                    if (ed.replace_phase == .search) {
                        break :blk @intCast(@min(search_cps, self.cols - 1));
                    } else {
                        const repl_cps = unicode.countCodepoints(ed.getReplaceText());
                        break :blk @intCast(@min(search_cps + 4 + repl_cps, self.cols - 1));
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

/// True when `pos` falls inside any of the sorted match ranges.
/// Early-exits on the first range starting past `pos`.
fn matchAt(matches: []const MatchRange, pos: usize) bool {
    for (matches) |m| {
        if (pos < m.start) return false;
        if (pos < m.end) return true;
    }
    return false;
}

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

test "render decodes multi-byte UTF-8 into a single cell" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = false;
    cfg.right_margin = 0;
    cfg.cursor_line_bg = false;

    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // "# ─\n" — '#' (1) + ' ' (1) + ─ (3) + '\n' (1) = 6 bytes.
    try ed.buf.insert(0, "# \xE2\x94\x80\n");
    ed.visible_cols = 20;
    ed.visible_rows = 4;

    var renderer = try Renderer.init(std.testing.allocator, 4, 20);
    defer renderer.deinit();

    _ = renderer.paintFrame(&ed);

    // No gutter, so character cells start at column 0.
    try std.testing.expectEqual(@as(u21, '#'), renderer.cellAt(0, 0).char);
    try std.testing.expectEqual(@as(u21, ' '), renderer.cellAt(0, 1).char);
    try std.testing.expectEqual(@as(u21, 0x2500), renderer.cellAt(0, 2).char);
    // The cell that USED to receive a continuation byte (0x94) must now
    // be untouched (a space from the initial clear).
    try std.testing.expectEqual(@as(u21, ' '), renderer.cellAt(0, 3).char);
}

fn bgEq(a: Color, b: Color) bool {
    return colorEq(a, b);
}

test "selection highlights character cells" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = false;
    cfg.right_margin = 0;
    cfg.cursor_line_bg = false;
    cfg.trailing_whitespace = false;

    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "hello\n");
    ed.visible_cols = 20;
    ed.visible_rows = 4;

    // Anchor at byte 0, cursor at byte 3 — selection covers "hel".
    ed.sel_active = true;
    ed.sel_anchor_line = 0;
    ed.sel_anchor_col = 0;
    ed.cursor.line = 0;
    ed.cursor.col = 3;

    var renderer = try Renderer.init(std.testing.allocator, 4, 20);
    defer renderer.deinit();

    _ = renderer.paintFrame(&ed);

    const sel_color = cfg.theme.selection;
    try std.testing.expect(bgEq(renderer.cellAt(0, 0).bg, sel_color));
    try std.testing.expect(bgEq(renderer.cellAt(0, 1).bg, sel_color));
    try std.testing.expect(bgEq(renderer.cellAt(0, 2).bg, sel_color));
    // Cell after the selection must NOT have selection bg.
    try std.testing.expect(!bgEq(renderer.cellAt(0, 3).bg, sel_color));
}

test "selection highlight covers tab expansion" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = false;
    cfg.right_margin = 0;
    cfg.cursor_line_bg = false;
    cfg.trailing_whitespace = false;
    // Default tab_width is 4.

    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // "a\tb\n" — 'a' at vis 0, tab fills vis 1..3 (4 cells: cols 1..3),
    // then 'b' at vis 4. Selection covering bytes 0..3 (a, tab, b)
    // means the tab cells must inherit the selection bg.
    try ed.buf.insert(0, "a\tb\n");
    ed.visible_cols = 20;
    ed.visible_rows = 4;

    ed.sel_active = true;
    ed.sel_anchor_line = 0;
    ed.sel_anchor_col = 0;
    ed.cursor.line = 0;
    ed.cursor.col = 3;

    var renderer = try Renderer.init(std.testing.allocator, 4, 20);
    defer renderer.deinit();

    _ = renderer.paintFrame(&ed);

    const sel = cfg.theme.selection;
    try std.testing.expect(bgEq(renderer.cellAt(0, 0).bg, sel)); // 'a'
    try std.testing.expect(bgEq(renderer.cellAt(0, 1).bg, sel)); // tab cell 1
    try std.testing.expect(bgEq(renderer.cellAt(0, 2).bg, sel)); // tab cell 2
    try std.testing.expect(bgEq(renderer.cellAt(0, 3).bg, sel)); // tab cell 3
    try std.testing.expect(bgEq(renderer.cellAt(0, 4).bg, sel)); // 'b'
}

test "multi-line comment stays highlighted when scrolled into" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = false;
    cfg.right_margin = 0;
    cfg.cursor_line_bg = false;

    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // A C file whose block comment opens on line 0 and never closes
    // before the viewport (scrolled to line 2).
    try ed.buf.insert(0, "/* opening\ninside one\ninside two\ninside three\n*/\nint x;\n");
    ed.language = syntax_mod.detect("t.c");
    ed.visible_cols = 40;
    ed.visible_rows = 4;
    ed.scroll_top = 2;

    var renderer = try Renderer.init(std.testing.allocator, 4, 40);
    defer renderer.deinit();

    _ = renderer.paintFrame(&ed);

    // "inside two" on the first visible row must render in the comment
    // color, not plain fg — the opening /* is above the viewport.
    const comment_color = cfg.theme.comment;
    try std.testing.expect(colorEq(renderer.cellAt(0, 0).fg, comment_color));
}

test "syntax cache invalidates when the comment opener is edited away" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = false;
    cfg.right_margin = 0;
    cfg.cursor_line_bg = false;

    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "/* c\nbody\n*/\n");
    ed.language = syntax_mod.detect("t.c");
    ed.visible_cols = 40;
    ed.visible_rows = 4;

    var renderer = try Renderer.init(std.testing.allocator, 4, 40);
    defer renderer.deinit();
    _ = renderer.paintFrame(&ed);
    try std.testing.expect(colorEq(renderer.cellAt(1, 0).fg, cfg.theme.comment));

    // Delete the opening "/*" — line 1 must stop being a comment.
    ed.buf.delete(0, 2);
    _ = renderer.paintFrame(&ed);
    try std.testing.expect(!colorEq(renderer.cellAt(1, 0).fg, cfg.theme.comment));
}

test "search mode highlights every visible match" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = false;
    cfg.right_margin = 0;
    cfg.cursor_line_bg = false;
    cfg.trailing_whitespace = false;

    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo bar foo\n");
    ed.visible_cols = 20;
    ed.visible_rows = 4;

    _ = ed.handleKey(.{ .ctrl = 'f' });
    for ("foo") |c| _ = ed.handleKey(.{ .char = c });

    var renderer = try Renderer.init(std.testing.allocator, 4, 20);
    defer renderer.deinit();
    _ = renderer.paintFrame(&ed);

    const sel = cfg.theme.selection;
    // Both occurrences tinted; the gap between them is not.
    try std.testing.expect(colorEq(renderer.cellAt(0, 0).bg, sel));
    try std.testing.expect(colorEq(renderer.cellAt(0, 2).bg, sel));
    try std.testing.expect(!colorEq(renderer.cellAt(0, 4).bg, sel));
    try std.testing.expect(colorEq(renderer.cellAt(0, 8).bg, sel));
}

test "status bar renders non-ASCII filename one codepoint per cell" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = try editor_mod.Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    const name = "r\xC3\xA9sum\xC3\xA9.md"; // résumé.md
    @memcpy(ed.filename[0..name.len], name);
    ed.filename_len = name.len;
    ed.visible_cols = 40;
    ed.visible_rows = 4;

    var renderer = try Renderer.init(std.testing.allocator, 4, 40);
    defer renderer.deinit();
    _ = renderer.paintFrame(&ed);

    const status_row: u16 = 3;
    try std.testing.expectEqual(@as(u21, 'r'), renderer.cellAt(status_row, 0).char);
    try std.testing.expectEqual(@as(u21, 0xE9), renderer.cellAt(status_row, 1).char);
    try std.testing.expectEqual(@as(u21, 's'), renderer.cellAt(status_row, 2).char);
}
