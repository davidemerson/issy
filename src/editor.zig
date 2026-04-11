//! Core editor state and logic.
//!
//! Manages the editing session: buffer, cursor(s), scroll position, mode,
//! syntax state, and configuration. Translates key events into editing
//! actions. Supports undo/redo, search/replace, bracket matching, and
//! indent detection.

const std = @import("std");
const Allocator = std.mem.Allocator;
const buffer_mod = @import("buffer.zig");
const syntax_mod = @import("syntax.zig");
const config_mod = @import("config.zig");
const term = @import("term.zig");
const unicode = @import("unicode.zig");

pub const Mode = enum { normal, search, command, confirm, replace };
pub const Action = enum { none, quit, force_quit, redraw, prompt };

pub const Cursor = struct {
    line: usize = 0,
    col: usize = 0,
    col_want: usize = 0,
    sel_active: bool = false,
    sel_anchor_line: usize = 0,
    sel_anchor_col: usize = 0,
};

const UndoEntry = struct {
    pos: usize,
    deleted: ?[]u8,
    inserted_len: usize,
};

pub const LineCol = struct { line: usize, col: usize };

pub const Editor = struct {
    buf: buffer_mod.Buffer,
    language: ?*const syntax_mod.Language = null,
    config: *config_mod.Config,
    allocator: Allocator,

    cursor: Cursor = .{},
    cursors: std.ArrayList(Cursor),

    scroll_top: usize = 0,
    scroll_left: usize = 0,
    visible_rows: u16 = 24,
    visible_cols: u16 = 80,

    filename: [std.fs.max_path_bytes]u8 = undefined,
    filename_len: usize = 0,
    modified: bool = false,

    mode: Mode = .normal,
    prompt_buf: [256]u8 = undefined,
    prompt_len: usize = 0,

    status_msg: [256]u8 = undefined,
    status_msg_len: usize = 0,
    status_msg_time: i64 = 0,

    search_pattern: [256]u8 = undefined,
    search_len: usize = 0,
    search_saved_line: usize = 0,
    search_saved_col: usize = 0,

    replace_buf: [256]u8 = undefined,
    replace_len: usize = 0,
    replace_phase: enum { search, replacement } = .search,

    sel_active: bool = false,
    sel_anchor_line: usize = 0,
    sel_anchor_col: usize = 0,

    matching_bracket_pos: ?LineCol = null,

    file_mtime: ?i128 = null,
    file_changed_on_disk: bool = false,

    undo_stack: std.ArrayList(UndoEntry),
    redo_stack: std.ArrayList(UndoEntry),

    clipboard: ?[]u8 = null,

    detected_expand_tabs: ?bool = null,
    detected_tab_width: ?u8 = null,

    confirm_action: enum { none, quit } = .none,
    command_action: enum { open, save_as } = .open,

    pub fn init(config: *config_mod.Config, allocator: Allocator) Editor {
        return .{
            .buf = buffer_mod.Buffer.init(allocator) catch @panic("failed to init buffer"),
            .config = config,
            .allocator = allocator,
            .cursors = .{},
            .undo_stack = .{},
            .redo_stack = .{},
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit();
        self.cursors.deinit(self.allocator);
        for (self.undo_stack.items) |entry| {
            if (entry.deleted) |d| self.allocator.free(d);
        }
        self.undo_stack.deinit(self.allocator);
        for (self.redo_stack.items) |entry| {
            if (entry.deleted) |d| self.allocator.free(d);
        }
        self.redo_stack.deinit(self.allocator);
        if (self.clipboard) |cb| self.allocator.free(cb);
    }

    pub fn openFile(self: *Editor, path: []const u8) !void {
        // Parse file:line syntax
        var actual_path = path;
        var goto_line: ?usize = null;

        if (std.mem.lastIndexOfScalar(u8, path, ':')) |colon| {
            if (colon > 0 and colon + 1 < path.len) {
                if (std.fmt.parseInt(usize, path[colon + 1 ..], 10)) |line_num| {
                    // Check that the part before colon is a valid file
                    const prefix = path[0..colon];
                    if (std.fs.cwd().access(prefix, .{})) |_| {
                        actual_path = prefix;
                        goto_line = if (line_num > 0) line_num - 1 else 0;
                    } else |_| {}
                } else |_| {}
            }
        }

        try self.buf.load(actual_path);

        // Store filename
        if (actual_path.len <= self.filename.len) {
            @memcpy(self.filename[0..actual_path.len], actual_path);
            self.filename_len = actual_path.len;
        }

        // Detect syntax
        self.language = syntax_mod.detect(actual_path);

        // Detect indent
        if (self.config.auto_detect_indent) {
            self.detectIndent();
        }

        // Record mtime
        self.updateMtime();

        self.modified = false;
        self.cursor = .{};
        self.scroll_top = 0;
        self.scroll_left = 0;

        // Jump to line if specified
        if (goto_line) |line| {
            const max_line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
            self.cursor.line = @min(line, max_line);
            self.ensureCursorVisible();
        }
    }

    fn updateMtime(self: *Editor) void {
        if (self.filename_len == 0) return;
        const fname = self.filename[0..self.filename_len];
        if (std.fs.cwd().openFile(fname, .{})) |file| {
            defer file.close();
            if (file.stat()) |stat| {
                self.file_mtime = stat.mtime;
            } else |_| {}
        } else |_| {}
    }

    pub fn checkFileChanged(self: *Editor) void {
        if (self.filename_len == 0) return;
        const fname = self.filename[0..self.filename_len];
        if (std.fs.cwd().openFile(fname, .{})) |file| {
            defer file.close();
            if (file.stat()) |stat| {
                if (self.file_mtime) |saved| {
                    if (stat.mtime != saved) {
                        self.file_changed_on_disk = true;
                    }
                }
            } else |_| {}
        } else |_| {}
    }

    pub fn detectIndent(self: *Editor) void {
        var tab_lines: usize = 0;
        var space_lines: usize = 0;
        var space_widths: [9]usize = .{0} ** 9; // index 1-8

        const max_lines = @min(self.buf.lineCount(), 100);
        var line_num: usize = 0;
        while (line_num < max_lines) : (line_num += 1) {
            const line_info = self.buf.getLine(line_num) orelse continue;
            if (line_info.len == 0) continue;

            var tmp: [256]u8 = undefined;
            const line_data = self.buf.contiguousSlice(line_info.start, @min(line_info.len, 256), &tmp);

            if (line_data.len > 0 and line_data[0] == '\t') {
                tab_lines += 1;
            } else if (line_data.len > 0 and line_data[0] == ' ') {
                space_lines += 1;
                var spaces: usize = 0;
                for (line_data) |c| {
                    if (c == ' ') spaces += 1 else break;
                }
                if (spaces >= 1 and spaces <= 8) {
                    space_widths[spaces] += 1;
                }
            }
        }

        const total = tab_lines + space_lines;
        if (total < 3) return; // Not enough data

        if (tab_lines * 10 > total * 6) {
            self.detected_expand_tabs = false;
        } else if (space_lines * 10 > total * 6) {
            self.detected_expand_tabs = true;
            // Detect most common width
            if (space_widths[2] >= space_widths[4]) {
                self.detected_tab_width = 2;
            } else {
                self.detected_tab_width = 4;
            }
        }
    }

    pub fn effectiveTabWidth(self: *const Editor) u8 {
        return self.detected_tab_width orelse self.config.tab_width;
    }

    fn effectiveExpandTabs(self: *const Editor) bool {
        return self.detected_expand_tabs orelse self.config.expand_tabs;
    }

    pub fn handleKey(self: *Editor, key: term.Key) Action {
        // Clear old status messages
        if (self.status_msg_len > 0) {
            const now = std.time.milliTimestamp();
            if (now - self.status_msg_time > 5000) {
                self.status_msg_len = 0;
            }
        }

        switch (self.mode) {
            .normal => return self.handleNormalKey(key),
            .search => return self.handleSearchKey(key),
            .command => return self.handleCommandKey(key),
            .confirm => return self.handleConfirmKey(key),
            .replace => return self.handleReplaceKey(key),
        }
    }

    fn handleNormalKey(self: *Editor, key: term.Key) Action {
        switch (key) {
            .char => |cp| {
                self.insertCodepoint(cp);
                return .redraw;
            },
            .enter => {
                self.insertNewline();
                return .redraw;
            },
            .tab => {
                self.insertTab();
                return .redraw;
            },
            .backspace => {
                self.doBackspace();
                return .redraw;
            },
            .delete => {
                self.doDelete();
                return .redraw;
            },
            .up => {
                self.moveCursorUp(1);
                return .redraw;
            },
            .down => {
                self.moveCursorDown(1);
                return .redraw;
            },
            .left => {
                self.moveCursorLeft();
                return .redraw;
            },
            .right => {
                self.moveCursorRight();
                return .redraw;
            },
            .home => {
                self.cursor.col = 0;
                self.cursor.col_want = 0;
                self.ensureCursorVisible();
                self.updateBracketMatch();
                return .redraw;
            },
            .end => {
                self.moveCursorToLineEnd();
                return .redraw;
            },
            .page_up => {
                const amount = if (self.visible_rows > 2) self.visible_rows - 2 else 1;
                self.moveCursorUp(amount);
                return .redraw;
            },
            .page_down => {
                const amount = if (self.visible_rows > 2) self.visible_rows - 2 else 1;
                self.moveCursorDown(amount);
                return .redraw;
            },
            .scroll_up => {
                if (self.scroll_top > 0) {
                    self.scroll_top -|= 3;
                    self.clampCursorToView();
                }
                return .redraw;
            },
            .scroll_down => {
                self.scroll_top += 3;
                const max_scroll = if (self.buf.lineCount() > self.visible_rows - 1)
                    self.buf.lineCount() - (self.visible_rows - 1)
                else
                    0;
                if (self.scroll_top > max_scroll) self.scroll_top = max_scroll;
                self.clampCursorToView();
                return .redraw;
            },
            .mouse_click => |pos| {
                self.handleMouseClick(pos.row, pos.col);
                return .redraw;
            },
            .ctrl => |c| {
                return self.handleCtrl(c);
            },
            .escape => {
                self.cursors.clearRetainingCapacity();
                self.sel_active = false;
                return .redraw;
            },
            else => return .none,
        }
    }

    fn handleCtrl(self: *Editor, c: u8) Action {
        switch (c) {
            'q', 'w' => {
                if (self.modified) {
                    self.mode = .confirm;
                    self.confirm_action = .quit;
                    self.setStatusMessage("Unsaved changes. Ctrl+Q to discard.");
                    return .redraw;
                }
                return .quit;
            },
            's' => {
                self.save();
                return .redraw;
            },
            'f' => {
                self.mode = .search;
                self.search_len = 0;
                self.search_saved_line = self.cursor.line;
                self.search_saved_col = self.cursor.col;
                return .redraw;
            },
            'h' => {
                self.mode = .replace;
                self.search_len = 0;
                self.replace_len = 0;
                self.replace_phase = .search;
                return .redraw;
            },
            'g' => {
                self.findNext();
                return .redraw;
            },
            'z' => {
                self.undo();
                return .redraw;
            },
            'y' => {
                self.redo();
                return .redraw;
            },
            'a' => {
                // Select all
                self.sel_active = true;
                self.sel_anchor_line = 0;
                self.sel_anchor_col = 0;
                const last_line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
                self.cursor.line = last_line;
                self.moveCursorToLineEnd();
                return .redraw;
            },
            'c' => {
                self.copySelection();
                return .redraw;
            },
            'x' => {
                self.cutSelection();
                return .redraw;
            },
            'v' => {
                self.paste();
                return .redraw;
            },
            'n' => {
                if (self.modified) {
                    self.mode = .confirm;
                    self.confirm_action = .quit; // reuse for new
                    self.setStatusMessage("Unsaved changes.");
                    return .redraw;
                }
                self.newBuffer();
                return .redraw;
            },
            'o' => {
                self.mode = .command;
                self.command_action = .open;
                self.prompt_len = 0;
                return .redraw;
            },
            'r' => {
                if (self.file_changed_on_disk and self.filename_len > 0) {
                    self.buf.load(self.filename[0..self.filename_len]) catch {
                        self.setStatusMessage("Failed to reload.");
                        return .redraw;
                    };
                    self.file_changed_on_disk = false;
                    self.modified = false;
                    self.updateMtime();
                    self.setStatusMessage("Reloaded.");
                }
                return .redraw;
            },
            'd' => {
                // Multi-cursor: select word under cursor, then add next occurrence
                self.addCursorAtNextOccurrence();
                return .redraw;
            },
            else => return .none,
        }
    }

    fn handleSearchKey(self: *Editor, key: term.Key) Action {
        switch (key) {
            .char => |cp| {
                if (self.search_len < 255) {
                    var enc_buf: [4]u8 = undefined;
                    const len = unicode.encode(cp, &enc_buf);
                    const space = 256 - self.search_len;
                    const copy_len = @min(len, space);
                    @memcpy(self.search_pattern[self.search_len..][0..copy_len], enc_buf[0..copy_len]);
                    self.search_len += copy_len;
                }
                // Incremental search
                self.findNext();
                return .redraw;
            },
            .backspace => {
                if (self.search_len > 0) self.search_len -= 1;
                return .redraw;
            },
            .enter => {
                self.mode = .normal;
                return .redraw;
            },
            .escape => {
                self.cursor.line = self.search_saved_line;
                self.cursor.col = self.search_saved_col;
                self.mode = .normal;
                self.ensureCursorVisible();
                return .redraw;
            },
            else => return .none,
        }
    }

    fn handleCommandKey(self: *Editor, key: term.Key) Action {
        switch (key) {
            .char => |cp| {
                if (self.prompt_len < 255) {
                    var enc_buf: [4]u8 = undefined;
                    const len = unicode.encode(cp, &enc_buf);
                    const space = 256 - self.prompt_len;
                    const copy_len = @min(len, space);
                    @memcpy(self.prompt_buf[self.prompt_len..][0..copy_len], enc_buf[0..copy_len]);
                    self.prompt_len += copy_len;
                }
                return .redraw;
            },
            .backspace => {
                if (self.prompt_len > 0) self.prompt_len -= 1;
                return .redraw;
            },
            .enter => {
                const path = self.prompt_buf[0..self.prompt_len];
                switch (self.command_action) {
                    .open => {
                        self.openFile(path) catch {
                            self.setStatusMessage("Failed to open file.");
                        };
                    },
                    .save_as => {
                        // Set filename and save
                        if (path.len > 0 and path.len <= self.filename.len) {
                            @memcpy(self.filename[0..path.len], path);
                            self.filename_len = path.len;
                            self.language = syntax_mod.detect(path);
                            self.buf.save(path) catch {
                                self.setStatusMessage("Save failed!");
                                self.mode = .normal;
                                return .redraw;
                            };
                            self.modified = false;
                            self.updateMtime();
                            self.setStatusMessage("Saved.");
                        }
                    },
                }
                self.mode = .normal;
                return .redraw;
            },
            .escape => {
                self.mode = .normal;
                return .redraw;
            },
            else => return .none,
        }
    }

    fn handleConfirmKey(self: *Editor, key: term.Key) Action {
        switch (key) {
            .ctrl => |c| {
                if (c == 'q' or c == 'w') {
                    return .force_quit;
                }
            },
            .escape => {
                self.mode = .normal;
                self.status_msg_len = 0;
                return .redraw;
            },
            else => {},
        }
        return .none;
    }

    fn handleReplaceKey(self: *Editor, key: term.Key) Action {
        switch (key) {
            .char => |cp| {
                var enc_buf: [4]u8 = undefined;
                const len = unicode.encode(cp, &enc_buf);
                switch (self.replace_phase) {
                    .search => {
                        if (self.search_len + len <= 256) {
                            @memcpy(self.search_pattern[self.search_len..][0..len], enc_buf[0..len]);
                            self.search_len += len;
                        }
                    },
                    .replacement => {
                        if (self.replace_len + len <= 256) {
                            @memcpy(self.replace_buf[self.replace_len..][0..len], enc_buf[0..len]);
                            self.replace_len += len;
                        }
                    },
                }
                return .redraw;
            },
            .backspace => {
                switch (self.replace_phase) {
                    .search => {
                        if (self.search_len > 0) self.search_len -= 1;
                    },
                    .replacement => {
                        if (self.replace_len > 0) self.replace_len -= 1;
                    },
                }
                return .redraw;
            },
            .tab => {
                self.replace_phase = if (self.replace_phase == .search) .replacement else .search;
                return .redraw;
            },
            .enter => {
                self.replaceCurrentAndNext();
                return .redraw;
            },
            .ctrl => |c| {
                if (c == 'a') {
                    self.replaceAll();
                    self.mode = .normal;
                    return .redraw;
                }
            },
            .escape => {
                self.mode = .normal;
                return .redraw;
            },
            else => {},
        }
        return .none;
    }

    // ── Cursor movement ──

    /// Compute wrap break points for a buffer line. Returns the number of
    /// visual sub-lines. breaks[i] is the starting buffer column of sub-line i.
    /// breaks[0] is always 0. Uses typesetting priorities: prefer breaking at
    /// spaces, then after punctuation/operators, then hard-break.
    pub const MAX_WRAP_BREAKS = 256;

    pub fn computeWrapBreaks(self: *Editor, line: usize, breaks: *[MAX_WRAP_BREAKS]usize) usize {
        breaks[0] = 0;
        if (!self.config.word_wrap) return 1;

        const info = self.buf.getLine(line) orelse return 1;
        const line_len = info.len;
        const w = self.wrapWidth();
        if (w == 0 or line_len <= w) return 1;

        var line_tmp: [8192]u8 = undefined;
        const data = self.buf.contiguousSlice(info.start, @min(line_len, 8192), &line_tmp);
        const cont_w = if (w > 2) w - 2 else 1;

        var count: usize = 1;
        var pos: usize = 0;
        var first = true;

        while (pos < data.len and count < MAX_WRAP_BREAKS) {
            const avail = if (first) w else cont_w;
            first = false;

            if (pos + avail >= data.len) break; // rest fits

            // Find the best break point within the available width
            const limit = pos + avail;
            var break_at = limit; // hard break fallback

            // Look backwards for a good break point (don't search more than 40% back)
            const min_scan = pos + avail * 3 / 5;
            var best_space: ?usize = null;
            var best_punct: ?usize = null;

            var scan = limit;
            while (scan > min_scan) {
                scan -= 1;
                const ch = data[scan];
                if (ch == ' ' or ch == '\t') {
                    best_space = scan + 1; // break after the space
                    break;
                }
                if (best_punct == null and isBreakAfter(ch)) {
                    best_punct = scan + 1; // break after the punctuation
                }
            }

            if (best_space) |bp| {
                break_at = bp;
            } else if (best_punct) |bp| {
                break_at = bp;
            }
            // else: hard break at limit

            breaks[count] = break_at;
            count += 1;
            pos = break_at;
        }

        return count;
    }

    fn isBreakAfter(ch: u8) bool {
        return switch (ch) {
            ',', ';', ')', ']', '}', '.', ':', '-', '/', '\\', '|', '&', '+', '=', '>' => true,
            else => false,
        };
    }

    /// Compute the starting buffer column of the Nth visual sub-line.
    fn subLineStartCol(self: *Editor, sub: usize) usize {
        if (sub == 0) return 0;
        var breaks: [MAX_WRAP_BREAKS]usize = undefined;
        const count = self.computeWrapBreaks(self.cursor.line, &breaks);
        if (sub < count) return breaks[sub];
        // Past the end — return line length
        return self.currentLineLen();
    }

    fn moveCursorUp(self: *Editor, count: u16) void {
        if (self.config.word_wrap) {
            var remaining: usize = count;
            while (remaining > 0) {
                const sub = self.cursorVisualSubLine();
                if (sub > 0) {
                    // Move up within wrapped line — preserve col_want relative to sub-line
                    self.cursor.col = self.subLineStartCol(sub - 1);
                    remaining -= 1;
                } else if (self.cursor.line > 0) {
                    // Move to previous buffer line — use col_want to preserve column
                    self.cursor.line -= 1;
                    const line_len = self.currentLineLen();
                    self.cursor.col = @min(self.cursor.col_want, line_len);
                    remaining -= 1;
                } else {
                    self.cursor.col = 0;
                    break;
                }
            }
        } else {
            if (self.cursor.line >= count) {
                self.cursor.line -= count;
            } else {
                self.cursor.line = 0;
            }
            self.clampCursorCol();
        }
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    fn moveCursorDown(self: *Editor, count: u16) void {
        if (self.config.word_wrap) {
            var remaining: usize = count;
            while (remaining > 0) {
                const sub = self.cursorVisualSubLine();
                const total_vlines = self.visualLinesForBufferLine(self.cursor.line);
                if (sub + 1 < total_vlines) {
                    // Move down within wrapped line
                    const target = self.subLineStartCol(sub + 1);
                    const line_len = self.currentLineLen();
                    self.cursor.col = @min(target, line_len);
                    remaining -= 1;
                } else {
                    // Move to next buffer line — use col_want to preserve column
                    const max_line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
                    if (self.cursor.line < max_line) {
                        self.cursor.line += 1;
                        const line_len = self.currentLineLen();
                        self.cursor.col = @min(self.cursor.col_want, line_len);
                        remaining -= 1;
                    } else {
                        self.moveCursorToLineEnd();
                        break;
                    }
                }
            }
        } else {
            self.cursor.line += count;
            const max_line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
            if (self.cursor.line > max_line) self.cursor.line = max_line;
            self.clampCursorCol();
        }
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    fn moveCursorLeft(self: *Editor) void {
        if (self.cursor.col > 0) {
            self.cursor.col -= 1;
        } else if (self.cursor.line > 0) {
            self.cursor.line -= 1;
            self.moveCursorToLineEnd();
            return;
        }
        self.cursor.col_want = self.cursor.col;
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    fn moveCursorRight(self: *Editor) void {
        const line_len = self.currentLineLen();
        if (self.cursor.col < line_len) {
            self.cursor.col += 1;
        } else if (self.cursor.line + 1 < self.buf.lineCount()) {
            self.cursor.line += 1;
            self.cursor.col = 0;
        }
        self.cursor.col_want = self.cursor.col;
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    fn moveCursorToLineEnd(self: *Editor) void {
        self.cursor.col = self.currentLineLen();
        self.cursor.col_want = self.cursor.col;
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    fn clampCursorCol(self: *Editor) void {
        const line_len = self.currentLineLen();
        self.cursor.col = @min(self.cursor.col_want, line_len);
    }

    fn clampCursorToView(self: *Editor) void {
        if (self.cursor.line < self.scroll_top) {
            self.cursor.line = self.scroll_top;
        }
        const bottom = self.scroll_top + @as(usize, self.visible_rows) -| 2;
        if (self.cursor.line > bottom) {
            self.cursor.line = bottom;
        }
        self.clampCursorCol();
    }

    fn handleMouseClick(self: *Editor, row: u16, col: u16) void {
        // Clear multi-cursors
        self.cursors.clearRetainingCapacity();
        self.sel_active = false;

        const target_line = self.scroll_top + row;
        const max_line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
        self.cursor.line = @min(target_line, max_line);

        // Account for centering offset and gutter
        const c_offset = self.centerOffset();
        const gutter_width = self.gutterWidth();
        const total_offset = c_offset + gutter_width;
        if (col >= total_offset) {
            self.cursor.col = @as(usize, col - total_offset) + self.scroll_left;
        } else {
            self.cursor.col = 0;
        }

        const line_len = self.currentLineLen();
        if (self.cursor.col > line_len) self.cursor.col = line_len;
        self.cursor.col_want = self.cursor.col;
        self.updateBracketMatch();
    }

    /// Compute the horizontal centering offset for wide terminals.
    pub fn centerOffset(self: *const Editor) u16 {
        const gw = @as(*Editor, @constCast(self)).gutterWidth();
        const rm = self.config.right_margin;
        const active_width: u16 = if (rm > 0)
            @intCast(@min(@as(u32, rm) + gw, self.visible_cols))
        else
            self.visible_cols;
        if (self.visible_cols > 130 and active_width < self.visible_cols)
            return (self.visible_cols - active_width) / 2;
        return 0;
    }

    pub fn gutterWidth(self: *const Editor) u16 {
        if (!self.config.line_numbers) return self.config.left_padding;

        const line_count = @as(*Editor, @constCast(self)).buf.lineCount();
        var digits: u16 = 1;
        var n = line_count;
        while (n >= 10) {
            n /= 10;
            digits += 1;
        }

        return self.config.left_padding + digits + self.config.gutter_padding;
    }

    fn currentLineLen(self: *Editor) usize {
        // getLine already returns length excluding the trailing newline
        const line_info = self.buf.getLine(self.cursor.line) orelse return 0;
        return line_info.len;
    }

    /// The number of columns available for code (accounts for gutter AND terminal width).
    /// This must match the renderer's actual code_end - code_start calculation.
    pub fn wrapWidth(self: *const Editor) usize {
        const gw = @as(*Editor, @constCast(self)).gutterWidth();
        const rm = self.config.right_margin;
        // Match renderer: code_end = min(right_margin + gutter_width, visible_cols)
        const code_end: usize = if (rm > 0)
            @min(@as(usize, rm) + gw, self.visible_cols)
        else
            self.visible_cols;
        if (code_end > gw) return code_end - gw;
        return 1;
    }

    /// How many visual (screen) rows a buffer line occupies when wrapped.
    pub fn visualLinesForBufferLine(self: *Editor, line: usize) usize {
        if (!self.config.word_wrap) return 1;
        var breaks: [MAX_WRAP_BREAKS]usize = undefined;
        return self.computeWrapBreaks(line, &breaks);
    }

    /// Which visual sub-line (0-based) the cursor is on within a wrapped line.
    pub fn cursorVisualSubLine(self: *Editor) usize {
        if (!self.config.word_wrap) return 0;
        var breaks: [MAX_WRAP_BREAKS]usize = undefined;
        const count = self.computeWrapBreaks(self.cursor.line, &breaks);
        // Find which sub-line contains cursor.col
        var sub: usize = 0;
        while (sub + 1 < count and breaks[sub + 1] <= self.cursor.col) {
            sub += 1;
        }
        return sub;
    }

    /// Get the screen column offset within the cursor's visual sub-line.
    pub fn cursorColInSubLine(self: *Editor) usize {
        if (!self.config.word_wrap) return self.cursor.col;
        var breaks: [MAX_WRAP_BREAKS]usize = undefined;
        const count = self.computeWrapBreaks(self.cursor.line, &breaks);
        var sub: usize = 0;
        while (sub + 1 < count and breaks[sub + 1] <= self.cursor.col) {
            sub += 1;
        }
        return self.cursor.col - breaks[sub];
    }

    fn ensureCursorVisible(self: *Editor) void {
        const margin: usize = self.config.scroll_margin;

        if (self.config.word_wrap) {
            // With wrapping, horizontal scroll is disabled
            self.scroll_left = 0;

            // Vertical: count visual rows from scroll_top to cursor
            // First, make sure scroll_top <= cursor.line
            if (self.cursor.line < self.scroll_top) {
                self.scroll_top = if (self.cursor.line > margin) self.cursor.line - margin else 0;
            }

            // Count visual rows from scroll_top to cursor line
            const visible = @as(usize, self.visible_rows) -| 1; // -1 for status bar
            var visual_rows: usize = 0;
            var line = self.scroll_top;
            while (line < self.cursor.line) : (line += 1) {
                visual_rows += self.visualLinesForBufferLine(line);
                if (visual_rows >= visible) break;
            }
            // Add cursor's sub-line within its wrapped line
            visual_rows += self.cursorVisualSubLine();

            if (visual_rows >= visible -| margin) {
                // Scroll down: advance scroll_top until cursor fits
                while (self.scroll_top < self.cursor.line) {
                    var vr: usize = 0;
                    var l = self.scroll_top;
                    while (l <= self.cursor.line) : (l += 1) {
                        vr += self.visualLinesForBufferLine(l);
                    }
                    if (vr <= visible) break;
                    self.scroll_top += 1;
                }
            }
        } else {
            // Non-wrapping mode: original logic
            if (self.cursor.line < self.scroll_top + margin) {
                self.scroll_top = if (self.cursor.line > margin) self.cursor.line - margin else 0;
            }
            const visible = @as(usize, self.visible_rows) -| 2;
            if (self.cursor.line >= self.scroll_top + visible -| margin) {
                self.scroll_top = self.cursor.line -| (visible -| margin -| 1);
            }

            // Horizontal
            const gw = self.gutterWidth();
            const code_cols = if (self.visible_cols > gw) @as(usize, self.visible_cols - gw) else 1;
            if (self.cursor.col < self.scroll_left) {
                self.scroll_left = self.cursor.col;
            }
            if (self.cursor.col >= self.scroll_left + code_cols) {
                self.scroll_left = self.cursor.col - code_cols + 1;
            }
        }
    }

    // ── Editing operations ──

    fn cursorBytePos(self: *Editor) usize {
        const line_info = self.buf.getLine(self.cursor.line) orelse return 0;
        return line_info.start + @min(self.cursor.col, line_info.len);
    }

    fn insertCodepoint(self: *Editor, cp: u21) void {
        var enc: [4]u8 = undefined;
        const len = unicode.encode(cp, &enc);
        const pos = self.cursorBytePos();

        self.pushUndo(pos, null, len);
        self.buf.insert(pos, enc[0..len]) catch return;
        self.cursor.col += 1;
        self.cursor.col_want = self.cursor.col;
        self.modified = true;
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    fn insertNewline(self: *Editor) void {
        const pos = self.cursorBytePos();
        var indent_buf: [256]u8 = undefined;
        var indent_len: usize = 0;

        // Auto-indent: copy leading whitespace from current line
        if (self.config.auto_indent) {
            if (self.buf.getLine(self.cursor.line)) |line_info| {
                var tmp: [256]u8 = undefined;
                const data = self.buf.contiguousSlice(line_info.start, @min(line_info.len, 256), &tmp);
                for (data) |c| {
                    if (c == ' ' or c == '\t') {
                        if (indent_len < indent_buf.len) {
                            indent_buf[indent_len] = c;
                            indent_len += 1;
                        }
                    } else break;
                }
            }
        }

        // Insert newline + indent
        var nl_buf: [257]u8 = undefined;
        nl_buf[0] = '\n';
        if (indent_len > 0) {
            @memcpy(nl_buf[1..][0..indent_len], indent_buf[0..indent_len]);
        }
        const total = 1 + indent_len;

        self.pushUndo(pos, null, total);
        self.buf.insert(pos, nl_buf[0..total]) catch return;
        self.cursor.line += 1;
        self.cursor.col = indent_len;
        self.cursor.col_want = self.cursor.col;
        self.modified = true;
        self.ensureCursorVisible();
    }

    fn insertTab(self: *Editor) void {
        const pos = self.cursorBytePos();
        if (self.effectiveExpandTabs()) {
            const tw = self.effectiveTabWidth();
            const spaces_needed = tw - @as(u8, @intCast(self.cursor.col % tw));
            var spaces: [8]u8 = .{' '} ** 8;
            self.pushUndo(pos, null, spaces_needed);
            self.buf.insert(pos, spaces[0..spaces_needed]) catch return;
            self.cursor.col += spaces_needed;
        } else {
            self.pushUndo(pos, null, 1);
            self.buf.insert(pos, "\t") catch return;
            self.cursor.col += 1;
        }
        self.cursor.col_want = self.cursor.col;
        self.modified = true;
        self.ensureCursorVisible();
    }

    fn doBackspace(self: *Editor) void {
        if (self.sel_active) {
            self.deleteSelection();
            return;
        }
        if (self.cursor.col == 0 and self.cursor.line == 0) return;

        if (self.cursor.col == 0) {
            // Join with previous line
            self.cursor.line -= 1;
            self.moveCursorToLineEnd();
            const pos = self.cursorBytePos();
            var del: [1]u8 = undefined;
            del[0] = '\n';
            const saved = self.allocator.dupe(u8, &del) catch return;
            self.pushUndo(pos, saved, 0);
            self.buf.delete(pos, 1);
        } else {
            self.cursor.col -= 1;
            const pos = self.cursorBytePos();
            var tmp: [1]u8 = undefined;
            const ch = self.buf.contiguousSlice(pos, 1, &tmp);
            const saved = self.allocator.dupe(u8, ch) catch return;
            self.pushUndo(pos, saved, 0);
            self.buf.delete(pos, 1);
        }
        self.cursor.col_want = self.cursor.col;
        self.modified = true;
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    fn doDelete(self: *Editor) void {
        const pos = self.cursorBytePos();
        const total_len = self.buf.logicalLen();
        if (pos >= total_len) return;

        var tmp: [1]u8 = undefined;
        const ch = self.buf.contiguousSlice(pos, 1, &tmp);
        const saved = self.allocator.dupe(u8, ch) catch return;
        self.pushUndo(pos, saved, 0);
        self.buf.delete(pos, 1);

        if (ch[0] == '\n') {
            // Lines merged, col stays
        }
        self.modified = true;
        self.updateBracketMatch();
    }

    fn deleteSelection(self: *Editor) void {
        if (!self.sel_active) return;
        const sel = self.getSelectionRange() orelse return;

        // Save deleted text
        var tmp_alloc = self.allocator.alloc(u8, sel.len) catch return;
        var tmp_buf: [4096]u8 = undefined;
        const data = self.buf.contiguousSlice(sel.start, sel.len, &tmp_buf);
        @memcpy(tmp_alloc[0..sel.len], data[0..sel.len]);

        self.pushUndo(sel.start, tmp_alloc, 0);
        self.buf.delete(sel.start, sel.len);

        // Move cursor to selection start
        self.cursor.line = sel.start_line;
        self.cursor.col = sel.start_col;
        self.cursor.col_want = self.cursor.col;
        self.sel_active = false;
        self.modified = true;
        self.ensureCursorVisible();
    }

    const SelectionRange = struct {
        start: usize,
        len: usize,
        start_line: usize,
        start_col: usize,
    };

    fn getSelectionRange(self: *Editor) ?SelectionRange {
        if (!self.sel_active) return null;

        const anchor_pos = self.lineColToBytePos(self.sel_anchor_line, self.sel_anchor_col);
        const cursor_pos = self.cursorBytePos();

        if (anchor_pos <= cursor_pos) {
            return .{
                .start = anchor_pos,
                .len = cursor_pos - anchor_pos,
                .start_line = self.sel_anchor_line,
                .start_col = self.sel_anchor_col,
            };
        } else {
            return .{
                .start = cursor_pos,
                .len = anchor_pos - cursor_pos,
                .start_line = self.cursor.line,
                .start_col = self.cursor.col,
            };
        }
    }

    fn lineColToBytePos(self: *Editor, line: usize, col: usize) usize {
        const line_info = self.buf.getLine(line) orelse return 0;
        return line_info.start + @min(col, line_info.len);
    }

    // ── Undo/Redo ──

    fn pushUndo(self: *Editor, pos: usize, deleted: ?[]u8, inserted_len: usize) void {
        self.undo_stack.append(self.allocator, .{
            .pos = pos,
            .deleted = deleted,
            .inserted_len = inserted_len,
        }) catch {};

        // Clear redo stack
        for (self.redo_stack.items) |entry| {
            if (entry.deleted) |d| self.allocator.free(d);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn undo(self: *Editor) void {
        if (self.undo_stack.items.len == 0) return;
        const entry = self.undo_stack.pop() orelse return;

        // Build the inverse redo entry as a single combined operation
        var redo_deleted: ?[]u8 = null;
        var redo_inserted_len: usize = 0;

        // First: undo the insertion (delete what was inserted)
        if (entry.inserted_len > 0) {
            if (entry.inserted_len <= 4096) {
                var tmp: [4096]u8 = undefined;
                const data = self.buf.contiguousSlice(entry.pos, entry.inserted_len, &tmp);
                redo_deleted = self.allocator.dupe(u8, data) catch null;
            }
            self.buf.delete(entry.pos, entry.inserted_len);
        }

        // Second: undo the deletion (re-insert what was deleted)
        if (entry.deleted) |del| {
            self.buf.insert(entry.pos, del) catch {};
            redo_inserted_len = del.len;
            self.allocator.free(del);
        }

        // Push a single combined redo entry
        self.redo_stack.append(self.allocator, .{
            .pos = entry.pos,
            .deleted = redo_deleted,
            .inserted_len = redo_inserted_len,
        }) catch {};

        self.modified = true;
        self.repositionCursorToBytePos(entry.pos);
    }

    fn redo(self: *Editor) void {
        if (self.redo_stack.items.len == 0) return;
        const entry = self.redo_stack.pop() orelse return;

        var undo_deleted: ?[]u8 = null;
        var undo_inserted_len: usize = 0;

        // First: undo the re-insertion (delete what was re-inserted)
        if (entry.inserted_len > 0) {
            if (entry.inserted_len <= 4096) {
                var tmp: [4096]u8 = undefined;
                const data = self.buf.contiguousSlice(entry.pos, entry.inserted_len, &tmp);
                undo_deleted = self.allocator.dupe(u8, data) catch null;
            }
            self.buf.delete(entry.pos, entry.inserted_len);
        }

        // Second: re-apply the original insertion
        if (entry.deleted) |del| {
            self.buf.insert(entry.pos, del) catch {};
            undo_inserted_len = del.len;
            self.allocator.free(del);
        }

        // Push a single combined undo entry
        self.undo_stack.append(self.allocator, .{
            .pos = entry.pos,
            .deleted = undo_deleted,
            .inserted_len = undo_inserted_len,
        }) catch {};

        self.modified = true;
        self.repositionCursorToBytePos(entry.pos);
    }

    fn repositionCursorToBytePos(self: *Editor, pos: usize) void {
        // Find line and col from byte position
        var line: usize = 0;
        while (line < self.buf.lineCount()) : (line += 1) {
            const info = self.buf.getLine(line) orelse break;
            if (pos >= info.start and pos <= info.start + info.len) {
                self.cursor.line = line;
                self.cursor.col = pos - info.start;
                self.cursor.col_want = self.cursor.col;
                self.ensureCursorVisible();
                return;
            }
        }
        // Fallback: go to end
        self.cursor.line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
        self.moveCursorToLineEnd();
    }

    // ── Search ──

    fn findNext(self: *Editor) void {
        if (self.search_len == 0) return;
        const pattern = self.search_pattern[0..self.search_len];
        const start_pos = self.cursorBytePos() + 1;
        const total = self.buf.logicalLen();

        // Search forward from cursor
        var pos = start_pos;
        while (pos + pattern.len <= total) : (pos += 1) {
            var tmp: [256]u8 = undefined;
            const slice = self.buf.contiguousSlice(pos, pattern.len, &tmp);
            if (std.mem.eql(u8, slice, pattern)) {
                self.repositionCursorToBytePos(pos);
                return;
            }
        }

        // Wrap around
        pos = 0;
        while (pos + pattern.len <= start_pos and pos + pattern.len <= total) : (pos += 1) {
            var tmp: [256]u8 = undefined;
            const slice = self.buf.contiguousSlice(pos, pattern.len, &tmp);
            if (std.mem.eql(u8, slice, pattern)) {
                self.repositionCursorToBytePos(pos);
                return;
            }
        }
    }

    fn replaceCurrentAndNext(self: *Editor) void {
        if (self.search_len == 0) return;
        const pattern = self.search_pattern[0..self.search_len];
        const replacement = self.replace_buf[0..self.replace_len];

        const pos = self.cursorBytePos();
        const total = self.buf.logicalLen();

        if (pos + pattern.len <= total) {
            var tmp: [256]u8 = undefined;
            const slice = self.buf.contiguousSlice(pos, pattern.len, &tmp);
            if (std.mem.eql(u8, slice, pattern)) {
                const saved = self.allocator.dupe(u8, slice) catch return;
                self.pushUndo(pos, saved, replacement.len);
                self.buf.delete(pos, pattern.len);
                self.buf.insert(pos, replacement) catch return;
                self.modified = true;
            }
        }
        self.findNext();
    }

    fn replaceAll(self: *Editor) void {
        if (self.search_len == 0) return;
        const pattern = self.search_pattern[0..self.search_len];
        const replacement = self.replace_buf[0..self.replace_len];
        var count: usize = 0;

        var pos: usize = 0;
        while (pos + pattern.len <= self.buf.logicalLen()) {
            var tmp: [256]u8 = undefined;
            const slice = self.buf.contiguousSlice(pos, pattern.len, &tmp);
            if (std.mem.eql(u8, slice, pattern)) {
                self.buf.delete(pos, pattern.len);
                self.buf.insert(pos, replacement) catch break;
                pos += replacement.len;
                count += 1;
            } else {
                pos += 1;
            }
        }
        if (count > 0) self.modified = true;
        var msg_buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&msg_buf, "{d} replacements", .{count}) catch return;
        self.setStatusMessageSlice(msg);
    }

    // ── Clipboard ──

    fn copySelection(self: *Editor) void {
        if (!self.sel_active) return;
        const sel = self.getSelectionRange() orelse return;
        if (sel.len == 0) return;

        if (self.clipboard) |cb| self.allocator.free(cb);

        var tmp: [4096]u8 = undefined;
        const data = self.buf.contiguousSlice(sel.start, sel.len, &tmp);
        self.clipboard = self.allocator.dupe(u8, data) catch null;
    }

    fn cutSelection(self: *Editor) void {
        self.copySelection();
        self.deleteSelection();
    }

    fn paste(self: *Editor) void {
        const cb = self.clipboard orelse return;
        if (cb.len == 0) return;

        if (self.sel_active) self.deleteSelection();

        const pos = self.cursorBytePos();
        self.pushUndo(pos, null, cb.len);
        self.buf.insert(pos, cb) catch return;
        self.modified = true;

        // Move cursor past pasted text
        self.repositionCursorToBytePos(pos + cb.len);
    }

    // ── Bracket matching ──

    fn updateBracketMatch(self: *Editor) void {
        self.matching_bracket_pos = null;

        const pos = self.cursorBytePos();
        if (pos >= self.buf.logicalLen()) return;

        var tmp: [1]u8 = undefined;
        const ch = self.buf.contiguousSlice(pos, 1, &tmp);
        if (ch.len == 0) return;

        const c = ch[0];
        const match_info: ?struct { target: u8, forward: bool } = switch (c) {
            '(' => .{ .target = ')', .forward = true },
            '[' => .{ .target = ']', .forward = true },
            '{' => .{ .target = '}', .forward = true },
            ')' => .{ .target = '(', .forward = false },
            ']' => .{ .target = '[', .forward = false },
            '}' => .{ .target = '{', .forward = false },
            else => null,
        };

        if (match_info) |info| {
            const max_scan = 10000;
            var depth: i32 = 1;

            if (info.forward) {
                var scan_pos = pos + 1;
                var scanned: usize = 0;
                while (scan_pos < self.buf.logicalLen() and scanned < max_scan) : ({
                    scan_pos += 1;
                    scanned += 1;
                }) {
                    var stmp: [1]u8 = undefined;
                    const sc = self.buf.contiguousSlice(scan_pos, 1, &stmp);
                    if (sc.len == 0) break;
                    if (sc[0] == c) depth += 1;
                    if (sc[0] == info.target) {
                        depth -= 1;
                        if (depth == 0) {
                            self.matching_bracket_pos = self.bytePosToLineCol(scan_pos);
                            return;
                        }
                    }
                }
            } else {
                if (pos == 0) return;
                var scan_pos = pos - 1;
                var scanned: usize = 0;
                while (scanned < max_scan) : (scanned += 1) {
                    var stmp: [1]u8 = undefined;
                    const sc = self.buf.contiguousSlice(scan_pos, 1, &stmp);
                    if (sc.len == 0) break;
                    if (sc[0] == c) depth += 1;
                    if (sc[0] == info.target) {
                        depth -= 1;
                        if (depth == 0) {
                            self.matching_bracket_pos = self.bytePosToLineCol(scan_pos);
                            return;
                        }
                    }
                    if (scan_pos == 0) break;
                    scan_pos -= 1;
                }
            }
        }
    }

    fn bytePosToLineCol(self: *Editor, pos: usize) LineCol {
        var line: usize = 0;
        while (line < self.buf.lineCount()) : (line += 1) {
            const info = self.buf.getLine(line) orelse break;
            if (pos >= info.start and pos < info.start + info.len) {
                return .{ .line = line, .col = pos - info.start };
            }
        }
        return .{ .line = 0, .col = 0 };
    }

    // ── Multi-cursor ──

    fn addCursorAtNextOccurrence(self: *Editor) void {
        // Get word under cursor
        const line_info = self.buf.getLine(self.cursor.line) orelse return;
        var line_tmp: [4096]u8 = undefined;
        const line_data = self.buf.contiguousSlice(line_info.start, @min(line_info.len, 4096), &line_tmp);

        const col = @min(self.cursor.col, line_data.len);

        // Find word boundaries
        var start = col;
        while (start > 0 and isWordChar(line_data[start - 1])) start -= 1;
        var end = col;
        while (end < line_data.len and isWordChar(line_data[end])) end += 1;

        if (start == end) return;
        const word = line_data[start..end];

        // Find next occurrence
        const search_start = line_info.start + end;
        var pos = search_start;
        while (pos + word.len <= self.buf.logicalLen()) : (pos += 1) {
            var tmp: [256]u8 = undefined;
            const slice = self.buf.contiguousSlice(pos, word.len, &tmp);
            if (std.mem.eql(u8, slice, word)) {
                const lc = self.bytePosToLineCol(pos);
                self.cursors.append(self.allocator, .{
                    .line = lc.line,
                    .col = lc.col,
                    .col_want = lc.col,
                }) catch {};
                return;
            }
        }
    }

    fn isWordChar(c: u8) bool {
        return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
    }

    // ── File operations ──

    fn save(self: *Editor) void {
        if (self.filename_len == 0) {
            self.mode = .command;
            self.command_action = .save_as;
            self.prompt_len = 0;
            return;
        }

        self.buf.save(self.filename[0..self.filename_len]) catch {
            self.setStatusMessage("Save failed!");
            return;
        };
        self.modified = false;
        self.updateMtime();
        self.file_changed_on_disk = false;
        self.setStatusMessage("Saved.");
    }

    fn newBuffer(self: *Editor) void {
        self.buf.deinit();
        self.buf = buffer_mod.Buffer.init(self.allocator) catch return;
        self.filename_len = 0;
        self.modified = false;
        self.cursor = .{};
        self.scroll_top = 0;
        self.scroll_left = 0;
        self.language = null;
        self.sel_active = false;
        self.cursors.clearRetainingCapacity();
    }

    pub fn setStatusMessage(self: *Editor, msg: []const u8) void {
        self.setStatusMessageSlice(msg);
    }

    fn setStatusMessageSlice(self: *Editor, msg: []const u8) void {
        const len = @min(msg.len, 256);
        @memcpy(self.status_msg[0..len], msg[0..len]);
        self.status_msg_len = len;
        self.status_msg_time = std.time.milliTimestamp();
    }

    pub fn getFilename(self: *const Editor) []const u8 {
        if (self.filename_len == 0) return "[untitled]";
        return self.filename[0..self.filename_len];
    }

    pub fn getStatusMsg(self: *const Editor) []const u8 {
        return self.status_msg[0..self.status_msg_len];
    }

    pub fn getPromptText(self: *const Editor) []const u8 {
        switch (self.mode) {
            .search => return self.search_pattern[0..self.search_len],
            .command => return self.prompt_buf[0..self.prompt_len],
            .replace => {
                // Combine search -> replacement
                return self.search_pattern[0..self.search_len];
            },
            .confirm => return self.status_msg[0..self.status_msg_len],
            .normal => return "",
        }
    }

    pub fn getReplaceText(self: *const Editor) []const u8 {
        return self.replace_buf[0..self.replace_len];
    }
};

// ── Tests ──

test "editor init and deinit" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try std.testing.expectEqual(@as(usize, 0), ed.cursor.line);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
    try std.testing.expectEqual(Mode.normal, ed.mode);
}

test "editor insert and cursor movement" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Insert "abc"
    _ = ed.handleKey(.{ .char = 'a' });
    _ = ed.handleKey(.{ .char = 'b' });
    _ = ed.handleKey(.{ .char = 'c' });

    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);
    try std.testing.expect(ed.modified);

    // Move left
    _ = ed.handleKey(.left);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.col);

    // Move right
    _ = ed.handleKey(.right);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);
}

test "editor backspace" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    _ = ed.handleKey(.{ .char = 'a' });
    _ = ed.handleKey(.{ .char = 'b' });
    _ = ed.handleKey(.backspace);

    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);
}

test "editor undo/redo" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    _ = ed.handleKey(.{ .char = 'x' });
    try std.testing.expectEqual(@as(usize, 1), ed.buf.logicalLen());

    // Undo
    _ = ed.handleKey(.{ .ctrl = 'z' });
    try std.testing.expectEqual(@as(usize, 0), ed.buf.logicalLen());

    // Redo
    _ = ed.handleKey(.{ .ctrl = 'y' });
    try std.testing.expectEqual(@as(usize, 1), ed.buf.logicalLen());
}

test "editor search mode" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Enter search mode
    _ = ed.handleKey(.{ .ctrl = 'f' });
    try std.testing.expectEqual(Mode.search, ed.mode);

    // Escape exits
    _ = ed.handleKey(.escape);
    try std.testing.expectEqual(Mode.normal, ed.mode);
}

test "editor quit with modifications" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    _ = ed.handleKey(.{ .char = 'x' });

    // First quit should ask for confirmation
    const action = ed.handleKey(.{ .ctrl = 'q' });
    try std.testing.expectEqual(Action.redraw, action);
    try std.testing.expectEqual(Mode.confirm, ed.mode);

    // Second quit forces
    const action2 = ed.handleKey(.{ .ctrl = 'q' });
    try std.testing.expectEqual(Action.force_quit, action2);
}

test "editor detect indent - spaces" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Insert lines with 2-space indent
    const content = "def foo():\n  x = 1\n  y = 2\n  z = 3\n  a = 4\n  b = 5\n  c = 6\n  d = 7\n  e = 8\n  f = 9\n";
    ed.buf.insert(0, content) catch unreachable;
    ed.detectIndent();

    try std.testing.expectEqual(@as(?bool, true), ed.detected_expand_tabs);
    try std.testing.expectEqual(@as(?u8, 2), ed.detected_tab_width);
}

test "editor bracket matching" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    ed.buf.insert(0, "(hello)") catch unreachable;
    ed.cursor.col = 0;
    ed.updateBracketMatch();

    try std.testing.expect(ed.matching_bracket_pos != null);
    if (ed.matching_bracket_pos) |pos| {
        try std.testing.expectEqual(@as(usize, 6), pos.col);
    }
}
