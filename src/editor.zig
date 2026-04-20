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
const positions_mod = @import("positions.zig");

pub const Mode = enum { normal, search, command, confirm, replace, help };
pub const Action = enum { none, quit, force_quit, redraw, prompt, export_pdf };

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
    /// Group identifier. 0 = standalone entry, non-zero = part of a group
    /// (all entries in a group share the same id). undo/redo process
    /// every entry with the same id as one atomic unit, which is how a
    /// multi-cursor insert or delete becomes a single undo step.
    group_id: u32 = 0,
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

    // Click-count state for double/triple-click word/line selection.
    // A click within CLICK_TIMEOUT_MS at the same buffer line+col
    // bumps the count. We use buffer position (not screen position)
    // so mid-sequence scrolling or autoscroll doesn't break the
    // streak.
    last_click_ms: i64 = 0,
    last_click_line: usize = 0,
    last_click_col: usize = 0,
    click_count: u8 = 0,

    // Drag state for autoscroll-past-viewport-edge. `is_dragging` is
    // true between a mouse_click/shift_click and the matching release.
    // `has_dragged` is only set once an actual mouse_drag event has
    // been delivered — this prevents a double/triple-click at row 0
    // (which sets is_dragging and sel_active but never moved) from
    // spuriously scrolling the view on the next idle tick.
    is_dragging: bool = false,
    has_dragged: bool = false,
    last_drag_row_raw: u16 = 0,
    last_drag_col_raw: u16 = 0,

    matching_bracket_pos: ?LineCol = null,

    file_mtime: ?i128 = null,
    file_changed_on_disk: bool = false,

    undo_stack: std.ArrayList(UndoEntry),
    redo_stack: std.ArrayList(UndoEntry),
    /// Monotonic counter. `nextUndoGroupId()` increments and returns it;
    /// each call yields a fresh id so every multi-cursor tick gets its
    /// own group that undo/redo can process atomically.
    undo_group_counter: u32 = 0,

    clipboard: ?[]u8 = null,

    detected_expand_tabs: ?bool = null,
    detected_tab_width: ?u8 = null,

    confirm_action: enum { none, quit, new, open } = .none,
    command_action: enum { open, save_as, goto_line } = .open,

    // True between a bracketed-paste start and end marker. While set,
    // insertNewline/insertTab skip their auto-indent and tab-expansion
    // logic so already-formatted pasted content comes in verbatim.
    in_paste: bool = false,

    // Coalesced-undo state. A run of consecutive word-char inserts,
    // each arriving within COALESCE_WINDOW_MS of the previous one at
    // the position where the previous one ended, gets appended onto a
    // single UndoEntry instead of pushing a new one per keystroke. A
    // non-char key, a whitespace char, or anything else resets the run
    // so Ctrl+Z undoes a whole word at a time instead of a letter at
    // a time.
    last_insert_ms: i64 = 0,
    last_insert_was_word: bool = false,

    // Tab completion state
    completion_hint: [512]u8 = undefined, // grayed-out suffix for unique completion
    completion_hint_len: usize = 0,
    completion_matches: [16][256]u8 = undefined, // up to 16 visible matches (filenames only)
    completion_match_lens: [16]usize = .{0} ** 16,
    completion_match_count: usize = 0,

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

        // If we're replacing an existing file's buffer, remember where
        // the cursor was so the next open of that same file restores.
        self.persistCursor();

        // Missing file → open as an empty new buffer bound to that
        // filename. This makes `issy newdoc.md` behave like a "create
        // new file" rather than surfacing a FileNotFound error.
        var is_new_file = false;
        self.buf.load(actual_path) catch |e| switch (e) {
            error.FileNotFound => {
                is_new_file = true;
                // Reset the buffer so any previously-loaded content
                // doesn't leak into the new-file session (Ctrl+O to a
                // missing path would otherwise keep the old buffer).
                self.buf.deinit();
                self.buf = buffer_mod.Buffer.init(self.allocator) catch return error.OutOfMemory;
            },
            else => return e,
        };

        // Store filename
        if (actual_path.len <= self.filename.len) {
            @memcpy(self.filename[0..actual_path.len], actual_path);
            self.filename_len = actual_path.len;
        }

        // Detect syntax
        self.language = syntax_mod.detect(actual_path);

        // Detect indent
        if (self.config.auto_detect_indent and !is_new_file) {
            self.detectIndent();
        }

        // Record mtime (no-op for a new file — updateMtime silently
        // ignores the missing path).
        self.updateMtime();

        self.modified = false;
        self.cursor = .{};
        self.scroll_top = 0;
        self.scroll_left = 0;

        if (is_new_file) {
            self.setStatusMessage("New file.");
            return;
        }

        // An explicit file:line override wins over any remembered
        // position; otherwise consult the positions store.
        if (goto_line) |line| {
            const max_line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
            self.cursor.line = @min(line, max_line);
            self.ensureCursorVisible();
        } else {
            self.restoreCursorFromPositions();
        }
    }

    /// Resolve `self.filename` to an absolute path into `buf` and
    /// return the slice, or null if `buf` is too small. Used for
    /// cursor-position persistence — we key on the absolute form so
    /// the same file opened via different relative paths still matches.
    ///
    /// Deliberately avoids `std.fs.Dir.realpath`, which resolves
    /// symlinks via `/proc/self/fd/N` and is unsupported on OpenBSD.
    /// Symlinks stay unresolved; absolute paths pass through unchanged,
    /// relatives get cwd-prefixed. Same tradeoff as the rest of the
    /// codebase (see commit a07881c for the prior migration).
    fn absFilename(self: *const Editor, buf: []u8) ?[]const u8 {
        if (self.filename_len == 0) return null;
        const fname = self.filename[0..self.filename_len];
        if (fname.len > 0 and fname[0] == '/') {
            if (fname.len > buf.len) return null;
            @memcpy(buf[0..fname.len], fname);
            return buf[0..fname.len];
        }
        const cwd = std.posix.getcwd(buf) catch return null;
        const needed = cwd.len + 1 + fname.len;
        if (needed > buf.len) return null;
        buf[cwd.len] = '/';
        @memcpy(buf[cwd.len + 1 ..][0..fname.len], fname);
        return buf[0..needed];
    }

    /// Save the current cursor's line/col under the current filename's
    /// realpath. Called on save, on open (for the outgoing buffer), and
    /// on quit. No-op if the file has no resolvable path yet.
    pub fn persistCursor(self: *const Editor) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = self.absFilename(&path_buf) orelse return;
        positions_mod.record(abs, self.cursor.line, self.cursor.col);
    }

    fn restoreCursorFromPositions(self: *Editor) void {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs = self.absFilename(&path_buf) orelse return;
        const pos = positions_mod.lookup(abs) orelse return;
        const max_line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
        self.cursor.line = @min(pos.line, max_line);
        if (self.buf.getLine(self.cursor.line)) |info| {
            self.cursor.col = @min(pos.col, info.len);
        } else {
            self.cursor.col = 0;
        }
        self.cursor.col_want = self.cursor.col;
        self.ensureCursorVisible();
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
            .help => {
                // Any key dismisses the help overlay
                self.mode = .normal;
                return .redraw;
            },
        }
    }

    fn handleNormalKey(self: *Editor, key: term.Key) Action {
        // Any non-.char event ends the current coalesced-undo run —
        // including Enter, Tab, arrows, mouse events, Ctrl keys, and
        // so on. insertCodepoint refreshes the run timestamp itself.
        switch (key) {
            .char => {},
            else => self.last_insert_ms = 0,
        }
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
                self.sel_active = false;
                self.moveCursorUp(1);
                return .redraw;
            },
            .down => {
                self.sel_active = false;
                self.moveCursorDown(1);
                return .redraw;
            },
            .left => {
                self.sel_active = false;
                self.moveCursorLeft();
                return .redraw;
            },
            .right => {
                self.sel_active = false;
                self.moveCursorRight();
                return .redraw;
            },
            .home => {
                self.sel_active = false;
                self.cursor.col = 0;
                self.cursor.col_want = 0;
                self.ensureCursorVisible();
                self.updateBracketMatch();
                return .redraw;
            },
            .end => {
                self.sel_active = false;
                self.moveCursorToLineEnd();
                return .redraw;
            },
            .shift_up => {
                self.extendOrStartSelection();
                self.moveCursorUp(1);
                return .redraw;
            },
            .shift_down => {
                self.extendOrStartSelection();
                self.moveCursorDown(1);
                return .redraw;
            },
            .shift_left => {
                self.extendOrStartSelection();
                self.moveCursorLeft();
                return .redraw;
            },
            .shift_right => {
                self.extendOrStartSelection();
                self.moveCursorRight();
                return .redraw;
            },
            .shift_home => {
                self.extendOrStartSelection();
                self.cursor.col = 0;
                self.cursor.col_want = 0;
                self.ensureCursorVisible();
                self.updateBracketMatch();
                return .redraw;
            },
            .shift_end => {
                self.extendOrStartSelection();
                self.moveCursorToLineEnd();
                return .redraw;
            },
            .ctrl_word_left => {
                self.sel_active = false;
                self.moveCursorWordLeft();
                return .redraw;
            },
            .ctrl_word_right => {
                self.sel_active = false;
                self.moveCursorWordRight();
                return .redraw;
            },
            .ctrl_shift_left => {
                self.extendOrStartSelection();
                self.moveCursorWordLeft();
                return .redraw;
            },
            .ctrl_shift_right => {
                self.extendOrStartSelection();
                self.moveCursorWordRight();
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
            .mouse_shift_click => |pos| {
                self.handleMouseShiftClick(pos.row, pos.col);
                return .redraw;
            },
            .mouse_drag => |pos| {
                self.handleMouseDrag(pos.row, pos.col);
                return .redraw;
            },
            .mouse_release => |pos| {
                self.handleMouseRelease(pos.row, pos.col);
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
            .help, .f1 => {
                self.mode = .help;
                return .redraw;
            },
            .paste_start => {
                // Selection replacement happens once up front so a
                // selection isn't re-deleted on every char of the paste.
                if (self.sel_active) self.deleteSelection();
                self.in_paste = true;
                return .redraw;
            },
            .paste_end => {
                self.in_paste = false;
                self.updateBracketMatch();
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
                    self.setStatusMessage("Unsaved changes. Enter or Ctrl+Q to discard, Esc to cancel.");
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
            'l' => {
                // Goto-line. Enter an empty command prompt; the enter
                // handler parses the digits and jumps.
                self.mode = .command;
                self.command_action = .goto_line;
                self.prompt_len = 0;
                self.completion_match_count = 0;
                self.completion_hint_len = 0;
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
                    self.confirm_action = .new;
                    self.setStatusMessage("Unsaved changes. Enter or Ctrl+Q to discard and start new, Esc to cancel.");
                    return .redraw;
                }
                self.newBuffer();
                return .redraw;
            },
            'o' => {
                if (self.modified) {
                    self.mode = .confirm;
                    self.confirm_action = .open;
                    self.setStatusMessage("Unsaved changes. Enter or Ctrl+Q to discard and open another file, Esc to cancel.");
                    return .redraw;
                }
                self.enterOpenPrompt();
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
            'p' => {
                // Export current buffer to PDF. Guard here so the main
                // loop only ever sees the action when it can succeed.
                if (self.filename_len == 0) {
                    self.setStatusMessage("Save file first to enable PDF export.");
                    return .redraw;
                }
                if (self.config.font_file_len == 0) {
                    self.setStatusMessage("Set font_file in ~/.issyrc to enable PDF export.");
                    return .redraw;
                }
                return .export_pdf;
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
        // Filesystem tab-completion only fires for path-shaped prompts.
        // Goto-line takes digits, not paths, so it skips that whole
        // machinery — prevents a stray directory listing from the tab key.
        const is_path_prompt = self.command_action == .open or self.command_action == .save_as;
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
                if (is_path_prompt) self.updateCompletions();
                return .redraw;
            },
            .backspace => {
                if (self.prompt_len > 0) self.prompt_len -= 1;
                if (is_path_prompt) self.updateCompletions();
                return .redraw;
            },
            .tab => {
                if (is_path_prompt) self.applyTabCompletion();
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
                            self.persistCursor();
                            self.setStatusMessage("Saved.");
                        }
                    },
                    .goto_line => {
                        const trimmed = std.mem.trim(u8, path, " \t");
                        if (std.fmt.parseInt(usize, trimmed, 10)) |n| {
                            // 1-indexed input; clamp into the buffer.
                            const last = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;
                            const target = if (n == 0) 0 else @min(n - 1, last);
                            self.sel_active = false;
                            self.cursor.line = target;
                            self.cursor.col = 0;
                            self.cursor.col_want = 0;
                            self.ensureCursorVisible();
                        } else |_| {
                            if (trimmed.len > 0) self.setStatusMessage("Not a line number.");
                        }
                    },
                }
                self.mode = .normal;
                self.completion_match_count = 0;
                self.completion_hint_len = 0;
                return .redraw;
            },
            .escape => {
                self.mode = .normal;
                self.completion_match_count = 0;
                self.completion_hint_len = 0;
                return .redraw;
            },
            else => return .none,
        }
    }

    fn handleConfirmKey(self: *Editor, key: term.Key) Action {
        const confirmed = switch (key) {
            .enter => true,
            .ctrl => |c| c == 'q' or c == 'w',
            .escape => {
                self.mode = .normal;
                self.confirm_action = .none;
                self.status_msg_len = 0;
                return .redraw;
            },
            else => false,
        };
        if (!confirmed) return .none;

        // Dispatch based on which action asked for confirmation.
        // Without this, Ctrl+N → Ctrl+Q used to silently force_quit
        // because handleConfirmKey ignored confirm_action.
        const action = self.confirm_action;
        self.confirm_action = .none;
        switch (action) {
            .quit, .none => return .force_quit,
            .new => {
                self.newBuffer();
                self.mode = .normal;
                self.status_msg_len = 0;
                return .redraw;
            },
            .open => {
                self.enterOpenPrompt();
                return .redraw;
            },
        }
    }

    fn enterOpenPrompt(self: *Editor) void {
        self.mode = .command;
        self.command_action = .open;
        self.status_msg_len = 0;
        // Seed prompt with CWD so Tab-completion starts somewhere useful.
        self.prompt_len = 0;
        if (std.posix.getcwd(self.prompt_buf[0..])) |cwd| {
            self.prompt_len = cwd.len;
            if (self.prompt_len < 255) {
                self.prompt_buf[self.prompt_len] = '/';
                self.prompt_len += 1;
            }
        } else |_| {}
        self.updateCompletions();
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

    /// Maximum delay in ms between clicks for them to count as a
    /// double/triple click. 400ms is the common desktop default.
    pub const CLICK_TIMEOUT_MS: i64 = 400;

    pub fn computeWrapBreaks(self: *Editor, line: usize, breaks: *[MAX_WRAP_BREAKS]usize) usize {
        breaks[0] = 0;
        if (!self.config.word_wrap) return 1;

        const info = self.buf.getLine(line) orelse return 1;
        const line_len = info.len;
        const w = self.wrapWidth();
        if (w == 0) return 1;

        var line_tmp: [8192]u8 = undefined;
        const data = self.buf.contiguousSlice(info.start, @min(line_len, 8192), &line_tmp);
        const cont_w = if (w > 2) w - 2 else 1;
        const tw = self.effectiveTabWidth();

        // Single forward scan tracking (byte_offset, visual_col) per
        // codepoint. Break candidates (last space, last punctuation byte)
        // are remembered in bytes so the recorded break positions stay
        // byte-indexed for callers. Tabs expand to the next tab stop.
        // Multi-byte UTF-8 sequences are advanced as a unit, so a break
        // never lands inside a sequence.

        var count: usize = 1;
        var pos: usize = 0; // byte offset of current sub-line start
        var first = true;

        while (pos < data.len and count < MAX_WRAP_BREAKS) {
            const avail = if (first) w else cont_w;
            first = false;

            // Walk forward measuring visual width, remembering break candidates.
            var visual: usize = 0;
            var i: usize = pos;
            var last_space_byte: ?usize = null;
            var last_space_visual: usize = 0;
            var last_punct_byte: ?usize = null;
            var last_punct_visual: usize = 0;

            while (i < data.len) {
                const b = data[i];
                if (b == '\n') break;

                const cp_visual: usize = if (b == '\t')
                    (tw - (visual % tw))
                else
                    1;
                const cp_len: usize = if (b == '\t' or b < 0x80)
                    1
                else
                    @max(@as(usize, unicode.utf8Len(b)), 1);

                // If this codepoint would push us past avail, stop here.
                if (visual + cp_visual > avail) break;

                visual += cp_visual;
                i += cp_len;

                // After consuming the codepoint, record candidates that
                // can break *after* this byte position.
                if (b == ' ' or b == '\t') {
                    last_space_byte = i;
                    last_space_visual = visual;
                } else if (isBreakAfter(b)) {
                    last_punct_byte = i;
                    last_punct_visual = visual;
                }
            }

            // If the entire remainder fit, no more breaks needed.
            if (i >= data.len or data[i] == '\n') break;

            // Decide where to break. Prefer last space, then last punct,
            // but only if they sit past the 60% lookback threshold (matches
            // the previous behavior — avoids wrapping pathologically early).
            const min_visual = avail * 3 / 5;
            var break_at: usize = i;
            if (last_space_byte) |bp| {
                if (last_space_visual >= min_visual) break_at = bp;
            } else if (last_punct_byte) |bp| {
                if (last_punct_visual >= min_visual) break_at = bp;
            }

            // Guard against zero-progress (line full of nonbreakable
            // codepoints wider than `avail`): force at least one byte.
            if (break_at <= pos) break_at = pos + @max(@as(usize, unicode.utf8Len(data[pos])), 1);

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
            self.cursor.col -= self.prevCodepointLen(self.cursor.line, self.cursor.col);
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
            self.cursor.col += self.codepointLenAt(self.cursor.line, self.cursor.col);
        } else if (self.cursor.line + 1 < self.buf.lineCount()) {
            self.cursor.line += 1;
            self.cursor.col = 0;
        }
        self.cursor.col_want = self.cursor.col;
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    /// Move cursor one word to the right. Skips any trailing non-word
    /// bytes at the cursor position, then skips word bytes, landing
    /// just past the next word's end. Crosses line boundaries by
    /// advancing to the start of the next line when stuck at EOL.
    /// Non-ASCII bytes are treated as non-word (matching the existing
    /// Ctrl+D multi-cursor word logic).
    fn moveCursorWordRight(self: *Editor) void {
        var line = self.cursor.line;
        var col = self.cursor.col;

        // If already at EOL, jump to next line.
        const cur_len0 = self.currentLineLenAt(line);
        if (col >= cur_len0) {
            if (line + 1 < self.buf.lineCount()) {
                line += 1;
                col = 0;
                self.cursor.line = line;
                self.cursor.col = col;
                self.cursor.col_want = col;
                self.ensureCursorVisible();
                self.updateBracketMatch();
                return;
            }
            return;
        }

        var tmp: [4096]u8 = undefined;
        const info = self.buf.getLine(line) orelse return;
        const data = self.buf.contiguousSlice(info.start, @min(info.len, 4096), &tmp);

        // Skip non-word bytes first (whitespace, punctuation,
        // non-ASCII). Walk by codepoint so we don't split multi-byte
        // sequences.
        while (col < data.len and !isWordChar(data[col])) {
            col += self.codepointLenAt(line, col);
        }
        // Then skip the word itself.
        while (col < data.len and isWordChar(data[col])) {
            col += 1;
        }

        self.cursor.line = line;
        self.cursor.col = col;
        self.cursor.col_want = col;
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    /// Move cursor one word to the left. Skips any immediately
    /// preceding non-word bytes, then skips word bytes backward,
    /// landing at the start of that word. Crosses line boundaries to
    /// the end of the previous line when at col 0.
    fn moveCursorWordLeft(self: *Editor) void {
        var line = self.cursor.line;
        var col = self.cursor.col;

        if (col == 0) {
            if (line == 0) return;
            line -= 1;
            col = self.currentLineLenAt(line);
            self.cursor.line = line;
            self.cursor.col = col;
            self.cursor.col_want = col;
            self.ensureCursorVisible();
            self.updateBracketMatch();
            return;
        }

        var tmp: [4096]u8 = undefined;
        const info = self.buf.getLine(line) orelse return;
        const data = self.buf.contiguousSlice(info.start, @min(info.len, 4096), &tmp);

        // Walk backward across any immediately preceding non-word
        // bytes (the ones between the current cursor and the word
        // we're jumping into). Step by codepoint so we don't land
        // inside a multi-byte sequence.
        while (col > 0 and col - 1 < data.len and !isWordChar(data[col - 1])) {
            col -= self.prevCodepointLen(line, col);
        }
        // Then walk backward over the word itself to its start.
        while (col > 0 and col - 1 < data.len and isWordChar(data[col - 1])) {
            col -= 1;
        }

        self.cursor.line = line;
        self.cursor.col = col;
        self.cursor.col_want = col;
        self.ensureCursorVisible();
        self.updateBracketMatch();
    }

    /// Byte length of `line` (excluding any newline). Defaults to 0
    /// if the line is out of range. Split out so word-movement can
    /// query a line other than the cursor's current line.
    fn currentLineLenAt(self: *Editor, line: usize) usize {
        const info = self.buf.getLine(line) orelse return 0;
        return info.len;
    }

    /// Length in bytes of the codepoint starting at `byte_col` on `line`.
    /// Returns 1 for ASCII or end-of-line; 2-4 for multi-byte UTF-8.
    fn codepointLenAt(self: *Editor, line: usize, byte_col: usize) usize {
        const info = self.buf.getLine(line) orelse return 1;
        if (byte_col >= info.len) return 1;
        var tmp: [4]u8 = undefined;
        const slice_len = @min(@as(usize, 4), info.len - byte_col);
        const data = self.buf.contiguousSlice(info.start + byte_col, slice_len, &tmp);
        if (data.len == 0) return 1;
        return @max(@as(usize, unicode.utf8Len(data[0])), 1);
    }

    /// Length in bytes of the codepoint *ending* at `byte_col` on `line`.
    /// Walks backward over any continuation bytes (0x80..0xBF) until a
    /// non-continuation byte; returns 1 if `byte_col == 0` or under any
    /// malformed condition.
    fn prevCodepointLen(self: *Editor, line: usize, byte_col: usize) usize {
        if (byte_col == 0) return 1;
        const info = self.buf.getLine(line) orelse return 1;
        var tmp: [4]u8 = undefined;
        const start = if (byte_col >= 4) byte_col - 4 else 0;
        const want = byte_col - start;
        const data = self.buf.contiguousSlice(info.start + start, want, &tmp);
        var n: usize = 1;
        while (n < data.len and n < 4) : (n += 1) {
            const b = data[data.len - n];
            if (!unicode.isContByte(b)) break;
        }
        return n;
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
        // Clear multi-cursors.
        self.cursors.clearRetainingCapacity();

        const pos = self.screenToBufferPos(row, col);

        // Click-count tracking for double/triple-click word/line
        // selection. A click within CLICK_TIMEOUT_MS at the same
        // buffer position bumps the count; anything else resets it.
        const now = std.time.milliTimestamp();
        if (now - self.last_click_ms < CLICK_TIMEOUT_MS and
            pos.line == self.last_click_line and
            pos.col == self.last_click_col)
        {
            self.click_count = @min(self.click_count + 1, 3);
        } else {
            self.click_count = 1;
        }
        self.last_click_ms = now;
        self.last_click_line = pos.line;
        self.last_click_col = pos.col;

        // Arm drag state for all click counts. `has_dragged` stays
        // false until a real mouse_drag event arrives, so idle-tick
        // autoscroll doesn't fire on a bare click at row 0.
        self.is_dragging = true;
        self.has_dragged = false;
        self.last_drag_row_raw = row;
        self.last_drag_col_raw = col;

        switch (self.click_count) {
            2 => {
                self.selectWordAt(pos.line, pos.col);
            },
            3 => {
                self.selectLineAt(pos.line);
            },
            else => {
                // Single click: clear prior selection, move cursor,
                // pre-arm anchor at click pos. A subsequent drag flips
                // sel_active = true using this anchor; no drag = no
                // selection.
                self.sel_active = false;
                self.cursor.line = pos.line;
                self.cursor.col = pos.col;
                self.cursor.col_want = self.cursor.col;
                self.sel_anchor_line = pos.line;
                self.sel_anchor_col = pos.col;
            },
        }

        self.updateBracketMatch();
    }

    fn handleMouseShiftClick(self: *Editor, row: u16, col: u16) void {
        // Shift+click extends the selection from the existing anchor
        // (or from the current cursor if no selection is active) to
        // the click position. Multi-cursors are cleared to match the
        // plain-click behavior.
        self.cursors.clearRetainingCapacity();

        // A shift+click always breaks the double/triple-click streak
        // so the next plain click starts a fresh single-click.
        self.click_count = 0;

        const pos = self.screenToBufferPos(row, col);

        if (!self.sel_active) {
            self.sel_anchor_line = self.cursor.line;
            self.sel_anchor_col = self.cursor.col;
            self.sel_active = true;
        }

        self.cursor.line = pos.line;
        self.cursor.col = pos.col;
        self.cursor.col_want = self.cursor.col;

        // A shift+click may be followed by a drag (button 36 in SGR
        // mouse); arm drag state so the drag extends the selection
        // smoothly and triggers autoscroll past viewport edges. Like
        // a plain click, has_dragged stays false until a real
        // mouse_drag event arrives.
        self.is_dragging = true;
        self.has_dragged = false;
        self.last_drag_row_raw = row;
        self.last_drag_col_raw = col;

        self.updateBracketMatch();
    }

    fn handleMouseDrag(self: *Editor, row: u16, col: u16) void {
        // Store the raw coordinates for autoscroll tick logic before
        // clamping. Mode-1002 terminals only send drag events when
        // the pointer moves, so a stationary pointer at the viewport
        // edge still needs the idle-tick autoscroll to keep
        // extending the selection.
        self.last_drag_row_raw = row;
        self.last_drag_col_raw = col;
        self.is_dragging = true;
        self.has_dragged = true;

        // Any drag breaks a double/triple-click streak.
        self.click_count = 0;

        const clamped = self.clampDragToView(row, col);
        const pos = self.screenToBufferPos(clamped.row, clamped.col);
        // First drag motion since the click flips sel_active on. The
        // anchor was set in handleMouseClick so getSelectionRange has a
        // valid starting point.
        self.sel_active = true;
        self.cursor.line = pos.line;
        self.cursor.col = pos.col;
        self.cursor.col_want = self.cursor.col;
        self.updateBracketMatch();
    }

    fn handleMouseRelease(self: *Editor, row: u16, col: u16) void {
        _ = row;
        _ = col;
        self.is_dragging = false;
        self.has_dragged = false;
        // If the user clicked without dragging, the anchor and cursor
        // collapse to the same position — discard the empty selection
        // so a single click doesn't leave a phantom selected range.
        if (self.sel_active) {
            if (self.getSelectionRange()) |s| {
                if (s.len == 0) self.sel_active = false;
            }
        }
    }

    /// Clamp a raw mouse (row, col) to the editable viewport so
    /// screenToBufferPos always gets an in-bounds cell. Used by drag
    /// handling so the selection endpoint tracks the viewport edge
    /// while the pointer sits outside it.
    fn clampDragToView(self: *Editor, row: u16, col: u16) struct { row: u16, col: u16 } {
        const max_row: u16 = if (self.visible_rows >= 2) self.visible_rows - 2 else 0;
        const clamped_row = @min(row, max_row);
        const max_col: u16 = if (self.visible_cols > 0) self.visible_cols - 1 else 0;
        const clamped_col = @min(col, max_col);
        return .{ .row = clamped_row, .col = clamped_col };
    }

    /// Called from the main loop on idle ticks while `is_dragging`
    /// is true. If the last raw drag coordinate sits at the viewport
    /// edge, scroll in that direction by one row/col and re-run the
    /// drag at the edge so the selection keeps growing. Returns true
    /// when something scrolled, so the caller can force a redraw.
    ///
    /// Gated on `has_dragged` — a stationary click with no drag
    /// never autoscrolls even if it happened at row 0 / the last row.
    pub fn dragAutoscrollTick(self: *Editor) bool {
        if (!self.is_dragging or !self.has_dragged) return false;

        var scrolled = false;
        const row = self.last_drag_row_raw;
        const col = self.last_drag_col_raw;

        // Editable region is rows [0, visible_rows - 2]. The last
        // row (visible_rows - 1) is the status bar.
        const max_editable_row: u16 = if (self.visible_rows >= 2) self.visible_rows - 2 else 0;

        // Vertical: row == 0 with content above → scroll up;
        // row >= max_editable_row with content below → scroll down.
        if (row == 0 and self.scroll_top > 0) {
            self.scroll_top -= 1;
            scrolled = true;
        } else if (row >= max_editable_row) {
            const line_count = self.buf.lineCount();
            const visible_editable: usize = if (self.visible_rows >= 2)
                @as(usize, self.visible_rows - 1)
            else
                1;
            if (line_count > visible_editable and
                self.scroll_top + visible_editable < line_count)
            {
                self.scroll_top += 1;
                scrolled = true;
            }
        }

        // Horizontal autoscroll (non-wrap mode only). The editable
        // column range starts after the gutter + centering offset.
        if (!self.config.word_wrap) {
            const total_offset: u16 = self.centerOffset() + self.gutterWidth();
            const max_col: u16 = if (self.visible_cols > 0) self.visible_cols - 1 else 0;

            if (col <= total_offset and self.scroll_left > 0) {
                self.scroll_left -= 1;
                scrolled = true;
            } else if (col >= max_col) {
                self.scroll_left += 1;
                scrolled = true;
            }
        }

        if (!scrolled) return false;

        // Re-run the drag at the (already in-range) pointer position
        // so the selection endpoint follows the newly-scrolled edge.
        // We deliberately don't update last_drag_*_raw — the next
        // idle tick will keep scrolling if the pointer is still at
        // the edge.
        const pos = self.screenToBufferPos(row, col);
        self.cursor.line = pos.line;
        self.cursor.col = pos.col;
        self.cursor.col_want = self.cursor.col;
        self.updateBracketMatch();
        return true;
    }

    /// Select the word under `col` on `line`. If the byte at `col` is
    /// a word character, walk forward and backward to find the word
    /// bounds; otherwise select just the single codepoint at `col`.
    /// Sets sel_active = true with anchor at word start and cursor
    /// at word end.
    fn selectWordAt(self: *Editor, line: usize, col: usize) void {
        const bounds = self.wordBoundsAt(line, col);
        self.sel_anchor_line = line;
        self.sel_anchor_col = bounds.start;
        self.sel_active = true;
        self.cursor.line = line;
        self.cursor.col = bounds.end;
        self.cursor.col_want = self.cursor.col;
    }

    /// Select the entire line. Anchor at column 0, cursor at the
    /// line's byte length (excluding the newline).
    fn selectLineAt(self: *Editor, line: usize) void {
        const info = self.buf.getLine(line) orelse return;
        self.sel_anchor_line = line;
        self.sel_anchor_col = 0;
        self.sel_active = true;
        self.cursor.line = line;
        self.cursor.col = info.len;
        self.cursor.col_want = self.cursor.col;
    }

    /// Walk the byte span of the word containing `col`. If `col` is
    /// on a word byte (ASCII alphanumeric or underscore), expand in
    /// both directions across word bytes. Otherwise return the span
    /// of the single codepoint at `col` so double-clicking punctuation
    /// still gives a one-glyph highlight.
    fn wordBoundsAt(self: *Editor, line: usize, col: usize) struct { start: usize, end: usize } {
        const info = self.buf.getLine(line) orelse return .{ .start = 0, .end = 0 };
        var tmp: [4096]u8 = undefined;
        const data = self.buf.contiguousSlice(info.start, @min(info.len, 4096), &tmp);
        const c = @min(col, data.len);

        if (c >= data.len or !isWordChar(data[c])) {
            // Non-word or end-of-line: select the single codepoint at
            // col, or a zero-width span if we're past the line end.
            if (c >= data.len) return .{ .start = c, .end = c };
            const cp_len = self.codepointLenAt(line, c);
            return .{ .start = c, .end = c + cp_len };
        }

        var start = c;
        while (start > 0 and isWordChar(data[start - 1])) start -= 1;
        var end = c;
        while (end < data.len and isWordChar(data[end])) end += 1;
        return .{ .start = start, .end = end };
    }

    /// Convert a (screen_row, screen_col) cell coordinate into a
    /// (buffer_line, buffer_col) position. Accounts for the gutter,
    /// centering offset, horizontal scroll, word-wrap continuation
    /// lines, tab expansion, and multi-byte UTF-8 codepoints. Clamps
    /// row to the buffer's last line and col to the line's byte length.
    fn screenToBufferPos(self: *Editor, row: u16, col: u16) struct { line: usize, col: usize } {
        const max_line = if (self.buf.lineCount() > 0) self.buf.lineCount() - 1 else 0;

        if (self.config.word_wrap) {
            // Walk from scroll_top, accumulating visual row heights,
            // to find which buffer line and sub-line the click lands on.
            var visual_rows_consumed: usize = 0;
            var file_line: usize = self.scroll_top;
            var sub_line: usize = 0;

            while (file_line <= max_line) {
                const vis_lines = self.visualLinesForBufferLine(file_line);
                if (visual_rows_consumed + vis_lines > row) {
                    sub_line = row - visual_rows_consumed;
                    break;
                }
                visual_rows_consumed += vis_lines;
                file_line += 1;
            }
            if (file_line > max_line) {
                file_line = max_line;
                sub_line = 0;
            }

            // Find the byte offset where this sub-line starts, convert
            // that to a visual column, then add the screen column offset
            // to get the absolute visual column within the line. Pass
            // through visualColToByteCol for proper tab/UTF-8 snapping.
            var breaks: [MAX_WRAP_BREAKS]usize = undefined;
            _ = self.computeWrapBreaks(file_line, &breaks);

            const c_offset = self.centerOffset();
            const gutter_width = self.gutterWidth();
            const code_start = c_offset + gutter_width;
            const cont_indent: u16 = if (sub_line > 0) 2 else 0;
            const total_col_offset = code_start + cont_indent;

            const sub_start_visual = self.byteColToVisualCol(file_line, breaks[sub_line]);
            const visual_col: usize = if (col >= total_col_offset)
                sub_start_visual + @as(usize, col - total_col_offset)
            else
                sub_start_visual;

            const target_col = self.visualColToByteCol(file_line, visual_col);

            return .{ .line = file_line, .col = target_col };
        }

        // No wrap: 1 screen row = 1 buffer line.
        const target_line = @min(self.scroll_top + row, max_line);

        const c_offset = self.centerOffset();
        const gutter_width = self.gutterWidth();
        const total_offset = c_offset + gutter_width;

        // `scroll_left` is tracked in visual columns (the renderer at
        // render.zig uses it as a visual-column threshold), so we add
        // it to the screen-cell column to get an absolute visual
        // column within the line, then reverse tab/multi-byte
        // expansion to land on the correct byte offset.
        const visual_col: usize = if (col >= total_offset)
            @as(usize, col - total_offset) + self.scroll_left
        else
            0;

        const target_col = self.visualColToByteCol(target_line, visual_col);

        return .{ .line = target_line, .col = target_col };
    }

    fn extendOrStartSelection(self: *Editor) void {
        if (!self.sel_active) {
            self.sel_anchor_line = self.cursor.line;
            self.sel_anchor_col = self.cursor.col;
            self.sel_active = true;
        }
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

    /// Convert a byte-offset column within `line` to the visual column
    /// it renders at (tabs expanded to the next tab stop). cursor.col
    /// and wrap_breaks[] are byte offsets; the renderer draws characters
    /// at visual columns. On lines without tabs the two are the same,
    /// but any tab introduces drift — on the MAINTAINER line in a
    /// Makefile, for instance, the byte column of "David" is 13 but
    /// its visual column is 16 because the tab between "=" and "David"
    /// expands to the next tab stop.
    pub fn byteColToVisualCol(self: *Editor, line: usize, byte_col: usize) usize {
        const info = self.buf.getLine(line) orelse return byte_col;
        var tmp: [8192]u8 = undefined;
        const data = self.buf.contiguousSlice(info.start, @min(info.len, 8192), &tmp);
        const tw = self.effectiveTabWidth();
        var visual: usize = 0;
        var i: usize = 0;
        const limit = @min(byte_col, data.len);
        while (i < limit) {
            const b = data[i];
            if (b == '\t') {
                visual += tw - (visual % tw);
                i += 1;
            } else if (b < 0x80) {
                visual += 1;
                i += 1;
            } else if (unicode.isContByte(b)) {
                // byte_col landed inside a multi-byte sequence — defensive
                // skip without counting. cursor.col is kept on codepoint
                // boundaries elsewhere, so this is a safety net only.
                i += 1;
            } else {
                const r = unicode.decode(data[i..]);
                visual += 1;
                i += @max(@as(usize, r.len), 1);
            }
        }
        return visual;
    }

    /// Inverse of `byteColToVisualCol`. Given a visual column on
    /// `line`, walk the line bytes accumulating visual width until we
    /// reach or pass `target_visual`, and return the byte offset of
    /// the codepoint whose visual span contains the target. Snaps
    /// left for clicks inside a tab cell (returns the byte position
    /// of the tab itself) and for the interior bytes of a multi-byte
    /// UTF-8 sequence. If `target_visual` is past the line's visual
    /// end, returns the line's byte length.
    pub fn visualColToByteCol(self: *Editor, line: usize, target_visual: usize) usize {
        const info = self.buf.getLine(line) orelse return 0;
        var tmp: [8192]u8 = undefined;
        const data = self.buf.contiguousSlice(info.start, @min(info.len, 8192), &tmp);
        const tw = self.effectiveTabWidth();
        var visual: usize = 0;
        var i: usize = 0;
        while (i < data.len) {
            const b = data[i];
            if (b == '\t') {
                const next_visual = visual + (tw - (visual % tw));
                if (target_visual < next_visual) return i;
                visual = next_visual;
                i += 1;
            } else if (b < 0x80) {
                if (target_visual <= visual) return i;
                visual += 1;
                i += 1;
            } else if (unicode.isContByte(b)) {
                // Defensive: landed inside a multi-byte sequence.
                i += 1;
            } else {
                if (target_visual <= visual) return i;
                const r = unicode.decode(data[i..]);
                visual += 1;
                i += @max(@as(usize, r.len), 1);
            }
        }
        return info.len;
    }

    /// Visual-column version of `cursorColInSubLine`. Accounts for tab
    /// expansion in both the sub-line start and the cursor position so
    /// the hardware cursor lands on the correct glyph on tab-bearing
    /// lines.
    pub fn cursorVisualColInSubLine(self: *Editor) usize {
        const cursor_visual = self.byteColToVisualCol(self.cursor.line, self.cursor.col);
        if (!self.config.word_wrap) return cursor_visual;
        var breaks: [MAX_WRAP_BREAKS]usize = undefined;
        const count = self.computeWrapBreaks(self.cursor.line, &breaks);
        var sub: usize = 0;
        while (sub + 1 < count and breaks[sub + 1] <= self.cursor.col) {
            sub += 1;
        }
        const sub_start_visual = self.byteColToVisualCol(self.cursor.line, breaks[sub]);
        return cursor_visual - sub_start_visual;
    }

    pub fn ensureCursorVisible(self: *Editor) void {
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

        if (self.sel_active) self.deleteSelection();

        if (self.cursors.items.len == 0) {
            // Fast path: single cursor. cursor.col is a byte offset into
            // the line, so advance it by the encoded length, not 1 — for
            // a 3-byte codepoint like ─ stepping by 1 would leave the
            // cursor on a continuation byte.
            const pos = self.cursorBytePos();
            const now = std.time.milliTimestamp();
            const this_is_word = isCodepointWordChar(cp);
            if (!self.tryCoalesceInsert(pos, len, now, this_is_word)) {
                self.pushUndo(pos, null, len);
            }
            self.buf.insert(pos, enc[0..len]) catch return;
            self.cursor.col += len;
            self.cursor.col_want = self.cursor.col;
            self.modified = true;
            self.last_insert_ms = now;
            self.last_insert_was_word = this_is_word;
            self.ensureCursorVisible();
            self.updateBracketMatch();
            return;
        }

        self.multiCursorInsert(enc[0..len]);
        // Multi-cursor edits already group themselves; they should
        // never fold into a coalesced run.
        self.last_insert_ms = 0;
        self.last_insert_was_word = false;
        self.updateBracketMatch();
    }

    fn insertNewline(self: *Editor) void {
        if (self.sel_active) self.deleteSelection();

        const pos = self.cursorBytePos();
        var indent_buf: [256]u8 = undefined;
        var indent_len: usize = 0;

        // Auto-indent: copy leading whitespace from current line.
        // Suppressed during a bracketed paste so the already-indented
        // pasted content doesn't compound on every embedded newline.
        if (self.config.auto_indent and !self.in_paste) {
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
        if (self.sel_active) self.deleteSelection();

        const pos = self.cursorBytePos();
        // Pasted tabs should land as literal '\t' regardless of the
        // expand-tabs setting, otherwise \t gets silently rewritten to
        // N spaces as it streams in.
        if (self.in_paste) {
            self.pushUndo(pos, null, 1);
            self.buf.insert(pos, "\t") catch return;
            self.cursor.col += 1;
            self.cursor.col_want = self.cursor.col;
            self.modified = true;
            self.ensureCursorVisible();
            return;
        }
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

        if (self.cursors.items.len == 0) {
            // Fast path: single cursor.
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
                // Delete the *whole* preceding codepoint, not one byte —
                // otherwise backspacing over `─` would leave behind two
                // continuation bytes and corrupt every following render.
                const del_len = self.prevCodepointLen(self.cursor.line, self.cursor.col);
                self.cursor.col -= del_len;
                const pos = self.cursorBytePos();
                var tmp: [4]u8 = undefined;
                const ch = self.buf.contiguousSlice(pos, del_len, &tmp);
                const saved = self.allocator.dupe(u8, ch) catch return;
                self.pushUndo(pos, saved, 0);
                self.buf.delete(pos, del_len);
            }
            self.cursor.col_want = self.cursor.col;
            self.modified = true;
            self.ensureCursorVisible();
            self.updateBracketMatch();
            return;
        }

        self.multiCursorDelete(.backward);
        self.updateBracketMatch();
    }

    fn doDelete(self: *Editor) void {
        if (self.cursors.items.len == 0) {
            const pos = self.cursorBytePos();
            const total_len = self.buf.logicalLen();
            if (pos >= total_len) return;

            // Delete the whole codepoint at the cursor, not one byte.
            const del_len = self.codepointLenAt(self.cursor.line, self.cursor.col);
            const remaining = total_len - pos;
            const eff_len = @min(del_len, remaining);
            var tmp: [4]u8 = undefined;
            const ch = self.buf.contiguousSlice(pos, eff_len, &tmp);
            const saved = self.allocator.dupe(u8, ch) catch return;
            self.pushUndo(pos, saved, 0);
            self.buf.delete(pos, eff_len);

            self.modified = true;
            self.updateBracketMatch();
            return;
        }

        self.multiCursorDelete(.forward);
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

    pub const SelectionRange = struct {
        start: usize,
        len: usize,
        start_line: usize,
        start_col: usize,
    };

    pub fn getSelectionRange(self: *Editor) ?SelectionRange {
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

    fn nextUndoGroupId(self: *Editor) u32 {
        self.undo_group_counter += 1;
        return self.undo_group_counter;
    }

    /// Max ms between consecutive word-char inserts for them to count
    /// as one undo run. Short enough that a pause-and-think doesn't
    /// glue unrelated edits; long enough that normal typing coalesces.
    const COALESCE_WINDOW_MS: i64 = 500;

    fn isCodepointWordChar(cp: u21) bool {
        return (cp >= 'a' and cp <= 'z') or
            (cp >= 'A' and cp <= 'Z') or
            (cp >= '0' and cp <= '9') or
            cp == '_';
    }

    /// Try to extend the top undo entry instead of pushing a new one.
    /// Returns true if the insert was folded into the existing entry.
    /// Callers still need to perform the actual buf.insert afterward.
    fn tryCoalesceInsert(self: *Editor, pos: usize, len: usize, now: i64, this_is_word: bool) bool {
        if (!this_is_word) return false;
        if (!self.last_insert_was_word) return false;
        if (self.undo_stack.items.len == 0) return false;
        if (now - self.last_insert_ms > COALESCE_WINDOW_MS) return false;

        const top = &self.undo_stack.items[self.undo_stack.items.len - 1];
        if (top.deleted != null) return false;
        if (top.group_id != 0) return false;
        if (top.pos + top.inserted_len != pos) return false;

        top.inserted_len += len;

        // A new edit invalidates the redo stack just like pushUndo does.
        for (self.redo_stack.items) |entry| {
            if (entry.deleted) |d| self.allocator.free(d);
        }
        self.redo_stack.clearRetainingCapacity();
        return true;
    }

    fn pushUndo(self: *Editor, pos: usize, deleted: ?[]u8, inserted_len: usize) void {
        self.pushUndoGrouped(pos, deleted, inserted_len, 0);
    }

    fn pushUndoGrouped(self: *Editor, pos: usize, deleted: ?[]u8, inserted_len: usize, group_id: u32) void {
        self.undo_stack.append(self.allocator, .{
            .pos = pos,
            .deleted = deleted,
            .inserted_len = inserted_len,
            .group_id = group_id,
        }) catch {};

        // Clear redo stack
        for (self.redo_stack.items) |entry| {
            if (entry.deleted) |d| self.allocator.free(d);
        }
        self.redo_stack.clearRetainingCapacity();
    }

    fn applyUndoEntry(self: *Editor, entry: UndoEntry) UndoEntry {
        // Invert a single entry and return the matching redo entry.
        var redo_deleted: ?[]u8 = null;
        var redo_inserted_len: usize = 0;

        if (entry.inserted_len > 0) {
            if (entry.inserted_len <= 4096) {
                var tmp: [4096]u8 = undefined;
                const data = self.buf.contiguousSlice(entry.pos, entry.inserted_len, &tmp);
                redo_deleted = self.allocator.dupe(u8, data) catch null;
            }
            self.buf.delete(entry.pos, entry.inserted_len);
        }

        if (entry.deleted) |del| {
            self.buf.insert(entry.pos, del) catch {};
            redo_inserted_len = del.len;
            self.allocator.free(del);
        }

        return .{
            .pos = entry.pos,
            .deleted = redo_deleted,
            .inserted_len = redo_inserted_len,
            .group_id = entry.group_id,
        };
    }

    fn undo(self: *Editor) void {
        if (self.undo_stack.items.len == 0) return;

        const top = self.undo_stack.items[self.undo_stack.items.len - 1];
        const group_id = top.group_id;

        // For ungrouped entries, process a single step. For grouped
        // entries, pop every entry carrying the same group_id in one
        // atomic unit so a multi-cursor tick undoes as a whole.
        var last_pos: usize = top.pos;
        while (self.undo_stack.items.len > 0) {
            const entry = self.undo_stack.items[self.undo_stack.items.len - 1];
            if (entry.group_id != group_id) break;
            _ = self.undo_stack.pop();
            const redo_entry = self.applyUndoEntry(entry);
            self.redo_stack.append(self.allocator, redo_entry) catch {};
            last_pos = entry.pos;
            if (group_id == 0) break; // ungrouped: single step
        }

        self.modified = true;
        // After a group undo, clear the multi-cursor set and put the
        // primary at the smallest restored position. This keeps the
        // post-undo state clean and predictable.
        self.cursors.clearRetainingCapacity();
        self.repositionCursorToBytePos(last_pos);
    }

    fn redo(self: *Editor) void {
        if (self.redo_stack.items.len == 0) return;

        const top = self.redo_stack.items[self.redo_stack.items.len - 1];
        const group_id = top.group_id;

        var last_pos: usize = top.pos;
        while (self.redo_stack.items.len > 0) {
            const entry = self.redo_stack.items[self.redo_stack.items.len - 1];
            if (entry.group_id != group_id) break;
            _ = self.redo_stack.pop();
            const undo_entry = self.applyUndoEntry(entry);
            self.undo_stack.append(self.allocator, undo_entry) catch {};
            last_pos = entry.pos;
            if (group_id == 0) break;
        }

        self.modified = true;
        self.cursors.clearRetainingCapacity();
        self.repositionCursorToBytePos(last_pos);
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

        // Read the selection into a freshly-sized buffer. The previous
        // implementation used a 4096-byte stack scratch here, which
        // would overflow on selections larger than 4 KB that happened
        // to straddle the gap.
        const data = self.allocator.alloc(u8, sel.len) catch return;
        const got = self.buf.contiguousSlice(sel.start, sel.len, data);
        if (got.ptr != data.ptr) @memcpy(data, got);

        if (self.clipboard) |cb| self.allocator.free(cb);
        self.clipboard = data;

        // Also push to the OS clipboard via OSC 52 when the terminal
        // is initialized. Internal paste (Ctrl+V) still reads from
        // self.clipboard, so Cmd+V in another app now works.
        term.writeOsc52Clipboard(data);
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

    /// Maximum cursor count across the primary + secondaries. Beyond
    /// this the extras are quietly dropped during multi-cursor edits.
    const MAX_CURSORS: usize = 64;

    /// Collect all active cursor byte positions into `out`, sorted
    /// descending and deduplicated. Returns the count written.
    fn collectCursorPositionsDesc(self: *Editor, out: *[MAX_CURSORS]usize) usize {
        var n: usize = 0;
        out[n] = self.cursorBytePos();
        n += 1;
        for (self.cursors.items) |c| {
            if (n >= MAX_CURSORS) break;
            out[n] = self.lineColToBytePos(c.line, c.col);
            n += 1;
        }
        std.mem.sort(usize, out[0..n], {}, std.sort.desc(usize));
        // Dedupe consecutive (they're adjacent after sort).
        var write: usize = 0;
        var read: usize = 0;
        while (read < n) : (read += 1) {
            if (write == 0 or out[write - 1] != out[read]) {
                out[write] = out[read];
                write += 1;
            }
        }
        return write;
    }

    /// Assign a set of byte positions back to the cursor set. The
    /// smallest position becomes the primary, the rest become
    /// secondaries. Positions are assumed to be valid byte offsets.
    fn assignCursorPositions(self: *Editor, positions: []usize) void {
        if (positions.len == 0) return;
        std.mem.sort(usize, positions, {}, std.sort.asc(usize));

        const primary_lc = self.bytePosToLineCol(positions[0]);
        self.cursor.line = primary_lc.line;
        self.cursor.col = primary_lc.col;
        self.cursor.col_want = self.cursor.col;

        self.cursors.clearRetainingCapacity();
        for (positions[1..]) |p| {
            const lc = self.bytePosToLineCol(p);
            self.cursors.append(self.allocator, .{
                .line = lc.line,
                .col = lc.col,
                .col_want = lc.col,
            }) catch {};
        }
    }

    /// Insert `bytes` at every active cursor position. Edits are
    /// applied from highest byte offset to lowest so earlier positions
    /// stay valid throughout. All resulting undo entries share one
    /// group_id so Ctrl+Z reverts the whole tick as a single unit.
    fn multiCursorInsert(self: *Editor, bytes: []const u8) void {
        var positions: [MAX_CURSORS]usize = undefined;
        const n = self.collectCursorPositionsDesc(&positions);
        if (n == 0 or bytes.len == 0) return;

        const group_id = self.nextUndoGroupId();

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const pos = positions[i];
            self.pushUndoGrouped(pos, null, bytes.len, group_id);
            self.buf.insert(pos, bytes) catch {
                // On failure, leave positions as-is and bail early — the
                // buffer may be in a partial state but further edits
                // would just compound the problem.
                return;
            };
            // Every previously-processed cursor (at higher positions)
            // shifts by +bytes.len because we just inserted earlier in
            // the buffer.
            for (0..i) |j| positions[j] += bytes.len;
            // This cursor ends up after the text it just inserted.
            positions[i] = pos + bytes.len;
        }

        self.assignCursorPositions(positions[0..n]);
        self.modified = true;
        self.ensureCursorVisible();
    }

    const DeleteDir = enum { forward, backward };

    /// Delete one byte at every active cursor. `.backward` is Backspace
    /// semantics (delete the byte BEFORE the cursor); `.forward` is
    /// Delete semantics (delete the byte AT the cursor).
    fn multiCursorDelete(self: *Editor, dir: DeleteDir) void {
        var positions: [MAX_CURSORS]usize = undefined;
        const n = self.collectCursorPositionsDesc(&positions);
        if (n == 0) return;

        const group_id = self.nextUndoGroupId();

        var i: usize = 0;
        while (i < n) : (i += 1) {
            const cursor_pos = positions[i];
            // Compute the byte position to delete and what the cursor's
            // new position becomes after the delete.
            var delete_pos: usize = undefined;
            var new_cursor_pos: usize = undefined;
            switch (dir) {
                .backward => {
                    // Skip cursors at the start of the buffer — nothing
                    // to delete behind them.
                    if (cursor_pos == 0) {
                        positions[i] = 0;
                        continue;
                    }
                    delete_pos = cursor_pos - 1;
                    new_cursor_pos = delete_pos;
                },
                .forward => {
                    if (cursor_pos >= self.buf.logicalLen()) {
                        // Nothing to delete at the end of the buffer.
                        continue;
                    }
                    delete_pos = cursor_pos;
                    new_cursor_pos = cursor_pos;
                },
            }

            var tmp: [1]u8 = undefined;
            const ch = self.buf.contiguousSlice(delete_pos, 1, &tmp);
            const saved = self.allocator.dupe(u8, ch) catch continue;
            self.pushUndoGrouped(delete_pos, saved, 0, group_id);
            self.buf.delete(delete_pos, 1);

            // Update all previously-processed positions (indices < i,
            // positions > delete_pos by construction of desc sort): they
            // each shift left by 1 because we removed a byte earlier in
            // the buffer.
            for (0..i) |j| {
                if (positions[j] > 0) positions[j] -= 1;
            }
            positions[i] = new_cursor_pos;
        }

        self.assignCursorPositions(positions[0..n]);
        self.modified = true;
        self.ensureCursorVisible();
    }

    fn addCursorAtNextOccurrence(self: *Editor) void {
        // Get word under primary cursor. The word serves as the search
        // needle for every Ctrl+D press; each press finds the next
        // occurrence after the furthest-already-added cursor.
        const line_info = self.buf.getLine(self.cursor.line) orelse return;
        var line_tmp: [4096]u8 = undefined;
        const line_data = self.buf.contiguousSlice(line_info.start, @min(line_info.len, 4096), &line_tmp);

        const col = @min(self.cursor.col, line_data.len);

        var start = col;
        while (start > 0 and isWordChar(line_data[start - 1])) start -= 1;
        var end = col;
        while (end < line_data.len and isWordChar(line_data[end])) end += 1;

        if (start == end) return;
        const word = line_data[start..end];

        // Start the search after the end of the word at whichever
        // cursor is furthest into the buffer. That's the primary's
        // word-end when there are no secondaries yet, or the end of
        // the last-added secondary's word on subsequent presses. This
        // is what makes repeat Ctrl+D cycle through the file instead
        // of pinning on the same next match.
        var search_start = line_info.start + end;
        for (self.cursors.items) |c| {
            const cursor_end = self.lineColToBytePos(c.line, c.col) + word.len;
            if (cursor_end > search_start) search_start = cursor_end;
        }

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
            if (std.posix.getcwd(self.prompt_buf[0..])) |cwd| {
                self.prompt_len = cwd.len;
                if (self.prompt_len < 255) {
                    self.prompt_buf[self.prompt_len] = '/';
                    self.prompt_len += 1;
                }
            } else |_| {}
            self.updateCompletions();
            return;
        }

        self.buf.save(self.filename[0..self.filename_len]) catch {
            self.setStatusMessage("Save failed!");
            return;
        };
        self.modified = false;
        self.updateMtime();
        self.file_changed_on_disk = false;
        // Re-detect syntax from the (possibly renamed) filename so
        // `:w foo.py` after opening `foo.txt` picks up Python highlighting.
        self.language = syntax_mod.detect(self.filename[0..self.filename_len]);
        // Refresh the positions store now that the file exists (the
        // first save of a new file would otherwise lose its cursor
        // state on quit since realpath would have failed earlier).
        self.persistCursor();
        self.setStatusMessage("Saved.");
    }

    // ── Tab completion ──

    fn updateCompletions(self: *Editor) void {
        self.completion_hint_len = 0;
        self.completion_match_count = 0;

        const path = self.prompt_buf[0..self.prompt_len];
        if (path.len == 0) return;

        // Split into directory and prefix
        const last_slash = std.mem.lastIndexOfScalar(u8, path, '/');
        const dir_path = if (last_slash) |s| path[0 .. s + 1] else "./";
        const prefix = if (last_slash) |s| path[s + 1 ..] else path;

        // Open directory
        var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
        const dir_slice = if (dir_path.len <= dir_buf.len)
            dir_buf[0..dir_path.len]
        else
            return;
        @memcpy(dir_slice, dir_path);

        var dir = std.fs.cwd().openDir(dir_slice, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        var match_count: usize = 0;
        var common_prefix_len: ?usize = null;
        var first_match: [256]u8 = undefined;
        var first_match_len: usize = 0;

        while (iter.next() catch null) |entry| {
            const name = entry.name;
            if (prefix.len > 0 and !std.mem.startsWith(u8, name, prefix)) continue;
            if (name[0] == '.' and (prefix.len == 0 or prefix[0] != '.')) continue; // hide dotfiles unless typing dot

            // Track this match
            if (match_count < 16) {
                const store_len = @min(name.len, 256);
                @memcpy(self.completion_matches[match_count][0..store_len], name[0..store_len]);
                // Append / for directories
                if (entry.kind == .directory and store_len < 255) {
                    self.completion_matches[match_count][store_len] = '/';
                    self.completion_match_lens[match_count] = store_len + 1;
                } else {
                    self.completion_match_lens[match_count] = store_len;
                }
            }

            // Track common prefix among all matches
            if (match_count == 0) {
                first_match_len = @min(name.len, 256);
                @memcpy(first_match[0..first_match_len], name[0..first_match_len]);
                common_prefix_len = first_match_len;
                // Add / suffix for single directory match
                if (entry.kind == .directory and first_match_len < 255) {
                    first_match[first_match_len] = '/';
                    first_match_len += 1;
                    common_prefix_len = first_match_len;
                }
            } else {
                // Narrow common prefix
                const cp = common_prefix_len.?;
                var i: usize = prefix.len;
                while (i < cp and i < name.len) : (i += 1) {
                    if (i >= first_match_len or first_match[i] != name[i]) break;
                }
                common_prefix_len = i;
            }

            match_count += 1;
        }

        self.completion_match_count = @min(match_count, 16);

        // If exactly one match, show the full hint grayed out
        if (match_count == 1 and first_match_len > prefix.len) {
            const hint = first_match[prefix.len..first_match_len];
            const hint_len = @min(hint.len, 512);
            @memcpy(self.completion_hint[0..hint_len], hint[0..hint_len]);
            self.completion_hint_len = hint_len;
        } else if (match_count > 1) {
            // Show common prefix extension as hint
            const cp = common_prefix_len orelse prefix.len;
            if (cp > prefix.len) {
                const hint = first_match[prefix.len..cp];
                const hint_len = @min(hint.len, 512);
                @memcpy(self.completion_hint[0..hint_len], hint[0..hint_len]);
                self.completion_hint_len = hint_len;
            }
        }
    }

    fn applyTabCompletion(self: *Editor) void {
        if (self.completion_hint_len == 0) return;

        // Append the hint to the prompt
        const space = 256 - self.prompt_len;
        const copy_len = @min(self.completion_hint_len, space);
        @memcpy(self.prompt_buf[self.prompt_len..][0..copy_len], self.completion_hint[0..copy_len]);
        self.prompt_len += copy_len;

        // Re-scan for new completions
        self.updateCompletions();
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
            .normal, .help => return "",
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

test "editor undo coalesces consecutive word-char inserts" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    for ("abc") |c| _ = ed.handleKey(.{ .char = c });
    try std.testing.expectEqual(@as(usize, 3), ed.buf.logicalLen());
    // Three letters typed in one run should collapse to a single
    // undo entry — Ctrl+Z removes the whole word at once.
    try std.testing.expectEqual(@as(usize, 1), ed.undo_stack.items.len);

    _ = ed.handleKey(.{ .ctrl = 'z' });
    try std.testing.expectEqual(@as(usize, 0), ed.buf.logicalLen());
}

test "editor undo splits on whitespace" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    for ("ab cd") |c| _ = ed.handleKey(.{ .char = c });
    // Three entries expected: "ab", " ", "cd".
    try std.testing.expectEqual(@as(usize, 3), ed.undo_stack.items.len);

    _ = ed.handleKey(.{ .ctrl = 'z' });
    // First undo drops "cd"
    try std.testing.expectEqualSlices(u8, "ab ", blk: {
        var tmp: [16]u8 = undefined;
        const s = ed.buf.contiguousSlice(0, ed.buf.logicalLen(), &tmp);
        break :blk s;
    });

    _ = ed.handleKey(.{ .ctrl = 'z' });
    // Next drops the space
    try std.testing.expectEqual(@as(usize, 2), ed.buf.logicalLen());

    _ = ed.handleKey(.{ .ctrl = 'z' });
    try std.testing.expectEqual(@as(usize, 0), ed.buf.logicalLen());
}

test "editor undo breaks run on cursor movement" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Seed one line then type, move, type.
    for ("ab") |c| _ = ed.handleKey(.{ .char = c });
    _ = ed.handleKey(.left);
    _ = ed.handleKey(.right);
    for ("cd") |c| _ = ed.handleKey(.{ .char = c });

    // The arrow keys should have broken the run — two entries, not one.
    try std.testing.expectEqual(@as(usize, 2), ed.undo_stack.items.len);
}

test "editor undo breaks run on Enter" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    for ("ab") |c| _ = ed.handleKey(.{ .char = c });
    _ = ed.handleKey(.enter);
    for ("cd") |c| _ = ed.handleKey(.{ .char = c });

    // ab + newline + cd = three entries.
    try std.testing.expectEqual(@as(usize, 3), ed.undo_stack.items.len);
}

test "byteColToVisualCol expands tabs to tab stops" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Same shape as the MAINTAINER line in packaging/openbsd/issy/Makefile:
    // "MAINTAINER =\tDavid Emerson <REPLACE...>"
    try ed.buf.insert(0, "MAINTAINER =\tDavid\n");

    // Bytes 0..11 are "MAINTAINER =" (12 chars), no tabs before, so
    // visual == byte for that whole range.
    try std.testing.expectEqual(@as(usize, 0), ed.byteColToVisualCol(0, 0));
    try std.testing.expectEqual(@as(usize, 10), ed.byteColToVisualCol(0, 10));
    try std.testing.expectEqual(@as(usize, 12), ed.byteColToVisualCol(0, 12));

    // Byte 12 is the tab. With tab_width=4, visual col BEFORE the tab
    // is 12 (which is a tab stop), so the tab advances visual to 16.
    // Byte 13 is 'D' — it renders at visual col 16.
    try std.testing.expectEqual(@as(usize, 16), ed.byteColToVisualCol(0, 13));

    // Byte 14 is 'a' — visual col 17.
    try std.testing.expectEqual(@as(usize, 17), ed.byteColToVisualCol(0, 14));

    // Byte 17 is 'd' (last of "David") — visual col 20.
    try std.testing.expectEqual(@as(usize, 20), ed.byteColToVisualCol(0, 17));
}

test "byteColToVisualCol with leading tab" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "\thello\n");

    // Byte 0 is the tab, at visual col 0. The tab advances visual to 4.
    try std.testing.expectEqual(@as(usize, 0), ed.byteColToVisualCol(0, 0));
    try std.testing.expectEqual(@as(usize, 4), ed.byteColToVisualCol(0, 1));
    try std.testing.expectEqual(@as(usize, 5), ed.byteColToVisualCol(0, 2));
}

test "tab-bearing short line reports single visual row" {
    // Regression for a render bug where a file containing tab characters
    // on short lines would render line 0 as an infinite cascade of wrap
    // continuations, hiding every subsequent line. Root cause: render.zig
    // terminated its char loop on `buf_col < sub_end_col` where buf_col
    // is a visual column and sub_end_col is a byte offset — tabs advance
    // buf_col faster than byte_idx, so buf_col reached sub_end_col early
    // and the loop exited before reaching end-of-line, which flipped
    // at_line_end to false and stranded the outer sub-line loop.
    //
    // This test pins the invariant at the wrap-computation layer: a
    // short line that fits in wrap width must report exactly one
    // visual row regardless of embedded tabs.

    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    const sample = "COMMENT =\ttiny text editor\nGH =\tdave\nfin\n";
    try ed.buf.insert(0, sample);

    // Buffer parsed at least three content lines (plus a possible
    // trailing empty line from the final '\n').
    try std.testing.expect(ed.buf.lineCount() >= 3);

    // Line 0 is ~26 bytes. With any sane wrap width (visible_cols wide
    // terminal, default right_margin=100), it fits in one visual row.
    ed.visible_cols = 120;
    ed.visible_rows = 10;

    var breaks: [Editor.MAX_WRAP_BREAKS]usize = undefined;
    try std.testing.expectEqual(@as(usize, 1), ed.computeWrapBreaks(0, &breaks));
    try std.testing.expectEqual(@as(usize, 1), ed.visualLinesForBufferLine(0));

    // Line 1 and line 2 likewise are short tab-bearing / plain lines.
    try std.testing.expectEqual(@as(usize, 1), ed.visualLinesForBufferLine(1));
    try std.testing.expectEqual(@as(usize, 1), ed.visualLinesForBufferLine(2));
}

test "multi-cursor insert types at every cursor" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Seed buffer: "aa aa aa"
    for ("aa aa aa") |c| _ = ed.handleKey(.{ .char = c });

    // Move cursor to the start of the first "aa".
    ed.cursor.line = 0;
    ed.cursor.col = 0;

    // Ctrl+D twice adds cursors at the next two "aa" occurrences.
    _ = ed.handleKey(.{ .ctrl = 'd' });
    _ = ed.handleKey(.{ .ctrl = 'd' });
    try std.testing.expectEqual(@as(usize, 2), ed.cursors.items.len);

    // Type "X" — should insert at all three cursor positions.
    _ = ed.handleKey(.{ .char = 'X' });

    var tmp: [32]u8 = undefined;
    const got = ed.buf.contiguousSlice(0, ed.buf.logicalLen(), &tmp);
    try std.testing.expectEqualStrings("Xaa Xaa Xaa", got);
}

test "multi-cursor delete removes at every cursor" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Seed buffer: "xa xa xa"
    for ("xa xa xa") |c| _ = ed.handleKey(.{ .char = c });

    ed.cursor.line = 0;
    ed.cursor.col = 0;

    _ = ed.handleKey(.{ .ctrl = 'd' });
    _ = ed.handleKey(.{ .ctrl = 'd' });
    try std.testing.expectEqual(@as(usize, 2), ed.cursors.items.len);

    // Forward-delete removes the "x" at each cursor position.
    _ = ed.handleKey(.delete);

    var tmp: [32]u8 = undefined;
    const got = ed.buf.contiguousSlice(0, ed.buf.logicalLen(), &tmp);
    try std.testing.expectEqualStrings("a a a", got);
}

test "multi-cursor edit is a single undo group" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Seed buffer: "aa aa"
    for ("aa aa") |c| _ = ed.handleKey(.{ .char = c });

    ed.cursor.line = 0;
    ed.cursor.col = 0;
    _ = ed.handleKey(.{ .ctrl = 'd' });

    // Type "Z" at both cursors.
    _ = ed.handleKey(.{ .char = 'Z' });

    var tmp: [32]u8 = undefined;
    var got = ed.buf.contiguousSlice(0, ed.buf.logicalLen(), &tmp);
    try std.testing.expectEqualStrings("Zaa Zaa", got);

    // One Ctrl+Z undoes the whole multi-cursor tick.
    _ = ed.handleKey(.{ .ctrl = 'z' });
    got = ed.buf.contiguousSlice(0, ed.buf.logicalLen(), &tmp);
    try std.testing.expectEqualStrings("aa aa", got);

    // Ctrl+Y re-applies the whole group.
    _ = ed.handleKey(.{ .ctrl = 'y' });
    got = ed.buf.contiguousSlice(0, ed.buf.logicalLen(), &tmp);
    try std.testing.expectEqualStrings("Zaa Zaa", got);
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

test "editor Ctrl+N on dirty buffer confirms then newBuffer" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    _ = ed.handleKey(.{ .char = 'x' });
    try std.testing.expect(ed.modified);

    // Ctrl+N -> confirm mode
    _ = ed.handleKey(.{ .ctrl = 'n' });
    try std.testing.expectEqual(Mode.confirm, ed.mode);

    // Enter confirms -> newBuffer() -> normal mode with clean buffer
    _ = ed.handleKey(.enter);
    try std.testing.expectEqual(Mode.normal, ed.mode);
    try std.testing.expect(!ed.modified);
    try std.testing.expectEqual(@as(usize, 0), ed.buf.logicalLen());
}

test "editor Ctrl+O on dirty buffer confirms then opens prompt" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    _ = ed.handleKey(.{ .char = 'x' });
    try std.testing.expect(ed.modified);

    // Ctrl+O -> confirm mode, not command mode
    _ = ed.handleKey(.{ .ctrl = 'o' });
    try std.testing.expectEqual(Mode.confirm, ed.mode);

    // Enter confirms -> command mode with .open action
    _ = ed.handleKey(.enter);
    try std.testing.expectEqual(Mode.command, ed.mode);

    // Escape cancels back to normal
    _ = ed.handleKey(.escape);
    try std.testing.expectEqual(Mode.normal, ed.mode);
    // Dirty buffer preserved
    try std.testing.expect(ed.modified);
}

test "editor Ctrl+O on clean buffer skips confirm" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Ctrl+O -> directly to command mode
    _ = ed.handleKey(.{ .ctrl = 'o' });
    try std.testing.expectEqual(Mode.command, ed.mode);
}

test "editor Ctrl+L goto-line jumps to line" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Seed 5 lines
    ed.buf.insert(0, "a\nb\nc\nd\ne\n") catch unreachable;

    // Ctrl+L -> command mode, goto_line action
    _ = ed.handleKey(.{ .ctrl = 'l' });
    try std.testing.expectEqual(Mode.command, ed.mode);

    // Type "3" and Enter -> jump to line 3 (0-indexed: 2)
    _ = ed.handleKey(.{ .char = '3' });
    _ = ed.handleKey(.enter);
    try std.testing.expectEqual(Mode.normal, ed.mode);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.line);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "editor goto-line clamps past-end to last line" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    ed.buf.insert(0, "a\nb\nc\n") catch unreachable;

    _ = ed.handleKey(.{ .ctrl = 'l' });
    _ = ed.handleKey(.{ .char = '9' });
    _ = ed.handleKey(.{ .char = '9' });
    _ = ed.handleKey(.enter);

    // Line count is 4 (including trailing empty line). Last index = 3.
    try std.testing.expectEqual(@as(usize, ed.buf.lineCount() - 1), ed.cursor.line);
}

test "editor goto-line Escape cancels" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    ed.buf.insert(0, "a\nb\nc\n") catch unreachable;
    ed.cursor.line = 1;

    _ = ed.handleKey(.{ .ctrl = 'l' });
    _ = ed.handleKey(.{ .char = '3' });
    _ = ed.handleKey(.escape);

    // Back to normal mode with cursor unchanged
    try std.testing.expectEqual(Mode.normal, ed.mode);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.line);
}

test "editor goto-line ignores non-numeric input" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    ed.buf.insert(0, "a\nb\nc\n") catch unreachable;
    ed.cursor.line = 2;

    _ = ed.handleKey(.{ .ctrl = 'l' });
    _ = ed.handleKey(.{ .char = 'x' });
    _ = ed.handleKey(.enter);

    try std.testing.expectEqual(Mode.normal, ed.mode);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.line);
}

test "editor confirm Escape restores buffer" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    _ = ed.handleKey(.{ .char = 'y' });
    _ = ed.handleKey(.{ .ctrl = 'n' });
    try std.testing.expectEqual(Mode.confirm, ed.mode);

    _ = ed.handleKey(.escape);
    try std.testing.expectEqual(Mode.normal, ed.mode);
    // The dirty buffer is still there and unchanged.
    try std.testing.expect(ed.modified);
    try std.testing.expectEqual(@as(usize, 1), ed.buf.logicalLen());
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

// ── UTF-8 handling ──

test "byteColToVisualCol handles multi-byte UTF-8" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // "a─b\n" — 'a' (1) + ─ (3) + 'b' (1) + '\n' (1) = 6 bytes
    try ed.buf.insert(0, "a\xE2\x94\x80b\n");

    try std.testing.expectEqual(@as(usize, 0), ed.byteColToVisualCol(0, 0));
    try std.testing.expectEqual(@as(usize, 1), ed.byteColToVisualCol(0, 1));
    // Past the 3-byte ─: visual col 2.
    try std.testing.expectEqual(@as(usize, 2), ed.byteColToVisualCol(0, 4));
    try std.testing.expectEqual(@as(usize, 3), ed.byteColToVisualCol(0, 5));
}

test "byteColToVisualCol with tab and multi-byte interleaved" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // "a\t─b\n" — tab_width default 4, 'a' at vis 0, tab fills to 4,
    // ─ at vis 4, 'b' at vis 5.
    try ed.buf.insert(0, "a\t\xE2\x94\x80b\n");

    try std.testing.expectEqual(@as(usize, 0), ed.byteColToVisualCol(0, 0));
    try std.testing.expectEqual(@as(usize, 1), ed.byteColToVisualCol(0, 1));
    try std.testing.expectEqual(@as(usize, 4), ed.byteColToVisualCol(0, 2)); // past tab
    try std.testing.expectEqual(@as(usize, 5), ed.byteColToVisualCol(0, 5)); // past ─
    try std.testing.expectEqual(@as(usize, 6), ed.byteColToVisualCol(0, 6)); // past b
}

test "computeWrapBreaks does not split multi-byte UTF-8" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // 60 ─ characters (180 bytes) + newline.
    var buf: [200]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        buf[n] = 0xE2;
        buf[n + 1] = 0x94;
        buf[n + 2] = 0x80;
        n += 3;
    }
    buf[n] = '\n';
    n += 1;
    try ed.buf.insert(0, buf[0..n]);

    // Force a narrow wrap window.
    ed.visible_cols = 30;
    ed.visible_rows = 20;
    ed.config.right_margin = 20;

    var breaks: [Editor.MAX_WRAP_BREAKS]usize = undefined;
    const count = ed.computeWrapBreaks(0, &breaks);
    try std.testing.expect(count > 1);

    // Every break offset must land on a codepoint boundary — never on a
    // continuation byte (0x80..0xBF).
    var line_tmp: [200]u8 = undefined;
    const line_info = ed.buf.getLine(0).?;
    const data = ed.buf.contiguousSlice(line_info.start, line_info.len, &line_tmp);
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const off = breaks[k];
        if (off >= data.len) continue;
        const b = data[off];
        try std.testing.expect(b & 0xC0 != 0x80);
    }
}

test "computeWrapBreaks measures width in codepoints not bytes" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // 30 ─ characters = 90 bytes but only 30 visual columns.
    var buf: [120]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        buf[n] = 0xE2;
        buf[n + 1] = 0x94;
        buf[n + 2] = 0x80;
        n += 3;
    }
    buf[n] = '\n';
    n += 1;
    try ed.buf.insert(0, buf[0..n]);

    // Wrap window: 50 columns. With byte-counting (90 > 50) the line
    // would wrap; with codepoint-counting (30 < 50) it must not.
    ed.visible_cols = 100;
    ed.visible_rows = 20;
    ed.config.right_margin = 50;

    var breaks: [Editor.MAX_WRAP_BREAKS]usize = undefined;
    const count = ed.computeWrapBreaks(0, &breaks);
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "insertCodepoint of 3-byte char advances cursor by codepoint" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Insert ─ (U+2500) — 3 bytes in UTF-8.
    _ = ed.handleKey(.{ .char = 0x2500 });
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);
    try std.testing.expectEqual(@as(usize, 3), ed.buf.logicalLen());

    // Insert another — cursor should land on a codepoint boundary again.
    _ = ed.handleKey(.{ .char = 0x2500 });
    try std.testing.expectEqual(@as(usize, 6), ed.cursor.col);
    try std.testing.expectEqual(@as(usize, 6), ed.buf.logicalLen());
}

test "moveCursorRight steps over multi-byte codepoint" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "a\xE2\x94\x80b");
    ed.cursor.line = 0;
    ed.cursor.col = 0;

    _ = ed.handleKey(.right);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);
    _ = ed.handleKey(.right);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor.col); // jumped over 3-byte ─
    _ = ed.handleKey(.right);
    try std.testing.expectEqual(@as(usize, 5), ed.cursor.col);
}

test "moveCursorLeft steps over multi-byte codepoint" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "a\xE2\x94\x80b");
    ed.cursor.line = 0;
    ed.cursor.col = 5;

    _ = ed.handleKey(.left);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor.col);
    _ = ed.handleKey(.left);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col); // jumped back over ─
    _ = ed.handleKey(.left);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "doBackspace deletes whole multi-byte codepoint" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "a\xE2\x94\x80");
    ed.cursor.line = 0;
    ed.cursor.col = 4;

    _ = ed.handleKey(.backspace);
    try std.testing.expectEqual(@as(usize, 1), ed.buf.logicalLen());
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);
}

test "doDelete forward removes whole multi-byte codepoint" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "a\xE2\x94\x80b");
    ed.cursor.line = 0;
    ed.cursor.col = 1;

    _ = ed.handleKey(.delete);
    try std.testing.expectEqual(@as(usize, 2), ed.buf.logicalLen());
    // Cursor stays put (byte 1 was 'a's end / ─'s start, now 'b's start)
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);
}

// ── Selection: keyboard ──

test "shift_right starts and extends selection" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "hello");
    ed.cursor.line = 0;
    ed.cursor.col = 0;

    _ = ed.handleKey(.shift_right);
    _ = ed.handleKey(.shift_right);

    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 0), ed.sel_anchor_line);
    try std.testing.expectEqual(@as(usize, 0), ed.sel_anchor_col);
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.col);

    const sr = ed.getSelectionRange().?;
    try std.testing.expectEqual(@as(usize, 2), sr.len);
}

test "shift_up extends across lines" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "hello\nworld\n");
    ed.cursor.line = 1;
    ed.cursor.col = 3;
    // moveCursorUp uses col_want when crossing into a new buffer line.
    // Real editing always keeps col_want in sync via the move helpers;
    // tests that seed cursor.col directly must do the same.
    ed.cursor.col_want = 3;

    _ = ed.handleKey(.shift_up);

    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 1), ed.sel_anchor_line);
    try std.testing.expectEqual(@as(usize, 3), ed.sel_anchor_col);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.line);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);

    // Selection covers "lo\nwor" — 2 + 1 (newline) + 3 = 6 bytes.
    const sr = ed.getSelectionRange().?;
    try std.testing.expectEqual(@as(usize, 6), sr.len);
}

test "plain right collapses active selection" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "hello");
    ed.cursor.line = 0;
    ed.cursor.col = 0;

    _ = ed.handleKey(.shift_right);
    _ = ed.handleKey(.shift_right);
    try std.testing.expect(ed.sel_active);

    _ = ed.handleKey(.right);
    try std.testing.expect(!ed.sel_active);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);
}

test "shift_left at line start crosses into previous line" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "hello\nworld\n");
    ed.cursor.line = 1;
    ed.cursor.col = 0;

    _ = ed.handleKey(.shift_left);

    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 1), ed.sel_anchor_line);
    try std.testing.expectEqual(@as(usize, 0), ed.sel_anchor_col);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.line);
    try std.testing.expectEqual(@as(usize, 5), ed.cursor.col);
}

test "shift_right over multi-byte char" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "a\xE2\x94\x80b");
    ed.cursor.line = 0;
    ed.cursor.col = 0;

    _ = ed.handleKey(.shift_right);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);
    _ = ed.handleKey(.shift_right);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor.col);

    const sr = ed.getSelectionRange().?;
    try std.testing.expectEqual(@as(usize, 4), sr.len);
}

test "Ctrl+A select all then Ctrl+C still works" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "hi");
    _ = ed.handleKey(.{ .ctrl = 'a' });
    try std.testing.expect(ed.sel_active);
    const sr = ed.getSelectionRange().?;
    try std.testing.expectEqual(@as(usize, 2), sr.len);

    _ = ed.handleKey(.{ .ctrl = 'c' });
    // Buffer unchanged.
    try std.testing.expectEqual(@as(usize, 2), ed.buf.logicalLen());
}

// ── Selection: mouse drag ──

test "mouse drag creates selection" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "abcdef\n");
    ed.visible_cols = 80;
    ed.visible_rows = 10;

    // gutter_width=0 in this config; click at col 1 -> buffer col 1.
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 1 } });
    try std.testing.expect(!ed.sel_active);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);
    try std.testing.expectEqual(@as(usize, 1), ed.sel_anchor_col);

    _ = ed.handleKey(.{ .mouse_drag = .{ .row = 0, .col = 4 } });
    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor.col);
    const sr = ed.getSelectionRange().?;
    try std.testing.expectEqual(@as(usize, 1), sr.start);
    try std.testing.expectEqual(@as(usize, 3), sr.len);
}

test "mouse release without drag clears selection" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "abcdef\n");
    ed.visible_cols = 80;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 2 } });
    _ = ed.handleKey(.{ .mouse_release = .{ .row = 0, .col = 2 } });
    try std.testing.expect(!ed.sel_active);
}

test "mouse drag past viewport clamps to last line" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "ab\ncd\n");
    ed.visible_cols = 80;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 0 } });
    // Drag to row 99 — should clamp to the last line (line 1 or 2).
    _ = ed.handleKey(.{ .mouse_drag = .{ .row = 99, .col = 0 } });
    try std.testing.expect(ed.sel_active);
    try std.testing.expect(ed.cursor.line <= ed.buf.lineCount());
}

// ── visualColToByteCol ──

test "visualColToByteCol identity on ASCII" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "abcdef\n");
    try std.testing.expectEqual(@as(usize, 0), ed.visualColToByteCol(0, 0));
    try std.testing.expectEqual(@as(usize, 3), ed.visualColToByteCol(0, 3));
    try std.testing.expectEqual(@as(usize, 6), ed.visualColToByteCol(0, 6));
    // Past the end clamps to info.len.
    try std.testing.expectEqual(@as(usize, 6), ed.visualColToByteCol(0, 99));
}

test "visualColToByteCol snaps inside tab to tab byte" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Default tab_width is 4. "\tabc" → tab covers visual 0..3,
    // 'a' at 4, 'b' at 5, 'c' at 6.
    try ed.buf.insert(0, "\tabc\n");

    // Visual cols 0..3 all fall inside the tab cell → snap to byte 0.
    try std.testing.expectEqual(@as(usize, 0), ed.visualColToByteCol(0, 0));
    try std.testing.expectEqual(@as(usize, 0), ed.visualColToByteCol(0, 1));
    try std.testing.expectEqual(@as(usize, 0), ed.visualColToByteCol(0, 3));
    try std.testing.expectEqual(@as(usize, 1), ed.visualColToByteCol(0, 4)); // 'a'
    try std.testing.expectEqual(@as(usize, 3), ed.visualColToByteCol(0, 6)); // 'c'
}

test "visualColToByteCol handles multi-byte codepoints" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // "a─b" — 'a' visual 0, ─ (3 bytes) visual 1, 'b' visual 2.
    try ed.buf.insert(0, "a\xE2\x94\x80b\n");

    try std.testing.expectEqual(@as(usize, 0), ed.visualColToByteCol(0, 0));
    try std.testing.expectEqual(@as(usize, 1), ed.visualColToByteCol(0, 1)); // ─ start
    try std.testing.expectEqual(@as(usize, 4), ed.visualColToByteCol(0, 2)); // 'b'
    try std.testing.expectEqual(@as(usize, 5), ed.visualColToByteCol(0, 3)); // EOL
}

test "screenToBufferPos clicks past tab land on next char" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // "\tabc": with tab_width=4, visual col 4 is 'a'. Clicking at
    // screen col 4 used to land on byte 4 (past "abc"); should now
    // land on byte 1 ('a').
    try ed.buf.insert(0, "\tabc\n");
    ed.visible_cols = 80;
    ed.visible_rows = 10;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 4 } });
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);

    // Clicking at col 5 → 'b' (byte 2).
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 5 } });
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.col);

    // Clicking inside the tab (col 2) snaps to the tab byte (0).
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 2 } });
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "screenToBufferPos clicks past multi-byte land correctly" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // "a─b" — 'a' visual 0, ─ visual 1, 'b' visual 2.
    try ed.buf.insert(0, "a\xE2\x94\x80b\n");
    ed.visible_cols = 80;
    ed.visible_rows = 10;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 2 } });
    // Should land on 'b' at byte 4, not byte 2 (inside the ─).
    try std.testing.expectEqual(@as(usize, 4), ed.cursor.col);
}

// ── Selection: shift+click and double/triple click ──

test "shift+click without selection anchors at current cursor" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "abcdefghij\n");
    ed.visible_cols = 80;
    ed.cursor.line = 0;
    ed.cursor.col = 2;

    _ = ed.handleKey(.{ .mouse_shift_click = .{ .row = 0, .col = 6 } });

    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 2), ed.sel_anchor_col);
    try std.testing.expectEqual(@as(usize, 6), ed.cursor.col);
    const sr = ed.getSelectionRange().?;
    try std.testing.expectEqual(@as(usize, 4), sr.len);
}

test "shift+click extends existing selection from original anchor" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "abcdefghij\n");
    ed.visible_cols = 80;
    ed.cursor.line = 0;
    ed.cursor.col = 1;

    // Build an initial 3-char selection via shift+right.
    _ = ed.handleKey(.shift_right);
    _ = ed.handleKey(.shift_right);
    _ = ed.handleKey(.shift_right);
    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 1), ed.sel_anchor_col);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor.col);

    // Shift+click further right — anchor must not move.
    _ = ed.handleKey(.{ .mouse_shift_click = .{ .row = 0, .col = 8 } });
    try std.testing.expectEqual(@as(usize, 1), ed.sel_anchor_col);
    try std.testing.expectEqual(@as(usize, 8), ed.cursor.col);
}

test "double click selects word" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo bar baz\n");
    ed.visible_cols = 80;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 5 } });
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 5 } });

    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 4), ed.sel_anchor_col);
    try std.testing.expectEqual(@as(usize, 7), ed.cursor.col);
}

test "double click on punctuation selects single char" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo,bar\n");
    ed.visible_cols = 80;

    // Click on the comma (col 3).
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 3 } });
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 3 } });

    try std.testing.expect(ed.sel_active);
    const sr = ed.getSelectionRange().?;
    try std.testing.expectEqual(@as(usize, 1), sr.len);
}

test "triple click selects line" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "first line\nsecond line\n");
    ed.visible_cols = 80;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 1, .col = 3 } });
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 1, .col = 3 } });
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 1, .col = 3 } });

    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 1), ed.sel_anchor_line);
    try std.testing.expectEqual(@as(usize, 0), ed.sel_anchor_col);
    try std.testing.expectEqual(@as(usize, 11), ed.cursor.col); // "second line".len
}

test "click count resets on different position" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo bar\n");
    ed.visible_cols = 80;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 1 } });
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 5 } });

    // Second click at a different buffer col → count resets to 1,
    // no word selection.
    try std.testing.expect(!ed.sel_active);
    try std.testing.expectEqual(@as(usize, 5), ed.cursor.col);
}

// ── Selection: word-wise keyboard ──

test "ctrl_shift_right extends selection to next word" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo bar baz\n");
    ed.cursor.line = 0;
    ed.cursor.col = 0;

    _ = ed.handleKey(.ctrl_shift_right);
    try std.testing.expect(ed.sel_active);
    // From col 0 ('f'): skip no non-word, skip "foo" → col 3.
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);

    _ = ed.handleKey(.ctrl_shift_right);
    // Skip " " → skip "bar" → col 7.
    try std.testing.expectEqual(@as(usize, 7), ed.cursor.col);
    try std.testing.expectEqual(@as(usize, 0), ed.sel_anchor_col);
}

test "ctrl_shift_left at BOF is noop" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo bar\n");
    ed.cursor.line = 0;
    ed.cursor.col = 0;

    _ = ed.handleKey(.ctrl_shift_left);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.line);
}

test "ctrl_word_right crosses line boundary at EOL" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo\nbar\n");
    ed.cursor.line = 0;
    ed.cursor.col = 3; // At EOL of "foo"

    _ = ed.handleKey(.ctrl_word_right);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.line);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "ctrl_word_right does not trigger search" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo bar\n");
    ed.cursor.line = 0;
    ed.cursor.col = 0;

    _ = ed.handleKey(.ctrl_word_right);
    // Must stay in normal mode — regression guard against the old
    // ctrl+right → .{ .ctrl = 'f' } → search-mode wiring.
    try std.testing.expectEqual(Mode.normal, ed.mode);
    try std.testing.expectEqual(@as(usize, 3), ed.cursor.col);
}

test "moveCursorWordLeft from mid-word goes to word start" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo bar\n");
    ed.cursor.line = 0;
    ed.cursor.col = 6; // mid "bar"

    _ = ed.handleKey(.ctrl_word_left);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor.col);
}

test "moveCursorWordLeft from space skips non-word then word" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "foo bar\n");
    ed.cursor.line = 0;
    ed.cursor.col = 4; // just before 'b' in "bar"

    _ = ed.handleKey(.ctrl_word_left);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

// ── Drag autoscroll ──

test "dragAutoscrollTick noop when not dragging" {
    var cfg = config_mod.Config.init();
    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "abc\n");
    ed.visible_rows = 10;
    ed.visible_cols = 80;
    ed.scroll_top = 0;

    try std.testing.expect(!ed.dragAutoscrollTick());
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_top);
}

test "dragAutoscrollTick scrolls down at bottom edge" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // 20 lines so scrolling is possible with visible_rows = 10.
    var buf: [128]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        buf[n] = 'a' + @as(u8, @intCast(i % 26));
        buf[n + 1] = '\n';
        n += 2;
    }
    try ed.buf.insert(0, buf[0..n]);

    ed.visible_rows = 10;
    ed.visible_cols = 80;

    // Click on last editable row (row 8 = visible_rows - 2).
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 8, .col = 0 } });
    _ = ed.handleKey(.{ .mouse_drag = .{ .row = 8, .col = 1 } });
    try std.testing.expect(ed.sel_active);
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_top);

    // Autoscroll tick should advance scroll_top by 1.
    try std.testing.expect(ed.dragAutoscrollTick());
    try std.testing.expectEqual(@as(usize, 1), ed.scroll_top);
}

test "dragAutoscrollTick scrolls up at top edge and clamps" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    var buf: [128]u8 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        buf[n] = 'a' + @as(u8, @intCast(i % 26));
        buf[n + 1] = '\n';
        n += 2;
    }
    try ed.buf.insert(0, buf[0..n]);
    ed.visible_rows = 10;
    ed.visible_cols = 80;
    ed.scroll_top = 5;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 0 } });
    _ = ed.handleKey(.{ .mouse_drag = .{ .row = 0, .col = 1 } });
    try std.testing.expect(ed.sel_active);

    // One tick scrolls up by 1.
    try std.testing.expect(ed.dragAutoscrollTick());
    try std.testing.expectEqual(@as(usize, 4), ed.scroll_top);

    // Run enough ticks to reach scroll_top = 0, then one more must
    // be a no-op clamped at 0.
    _ = ed.dragAutoscrollTick();
    _ = ed.dragAutoscrollTick();
    _ = ed.dragAutoscrollTick();
    _ = ed.dragAutoscrollTick();
    try std.testing.expectEqual(@as(usize, 0), ed.scroll_top);
    try std.testing.expect(!ed.dragAutoscrollTick());
}

test "mouse release clears is_dragging" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    try ed.buf.insert(0, "abcdef\n");
    ed.visible_cols = 80;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 0, .col = 0 } });
    try std.testing.expect(ed.is_dragging);

    _ = ed.handleKey(.{ .mouse_release = .{ .row = 0, .col = 0 } });
    try std.testing.expect(!ed.is_dragging);
}

test "mouse click on wrapped continuation line" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = true;
    cfg.right_margin = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // With visible_cols=20 and no gutter, wrapWidth()=20.
    // "aaaaa..." (25 chars) wraps: sub-line 0 = cols 0-19, sub-line 1 = cols 20-24.
    // Screen row 0 = line 0 sub-line 0, screen row 1 = line 0 sub-line 1.
    // "bbb\n" is on screen row 2 = line 1.
    try ed.buf.insert(0, "aaaaaaaaaaaaaaaaaaaaaaaaa\nbbb\n");
    ed.visible_cols = 20;
    ed.visible_rows = 10;

    // Click on screen row 1 (continuation of line 0). col 2 is the
    // continuation indent, so col 3 maps to visual col 20+1 = byte 21.
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 1, .col = 3 } });
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.line);
    try std.testing.expectEqual(@as(usize, 21), ed.cursor.col);

    // Click on screen row 2 — should land on line 1 (after the wrapped line).
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 2, .col = 1 } });
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.line);
    try std.testing.expectEqual(@as(usize, 1), ed.cursor.col);
}

test "mouse click after multiple wrapped lines" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = true;
    cfg.right_margin = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // Two long lines that each wrap into 2 screen rows at width 20,
    // followed by a short line.
    // Line 0: 25 chars -> screen rows 0-1
    // Line 1: 25 chars -> screen rows 2-3
    // Line 2: "end" -> screen row 4
    try ed.buf.insert(0, "aaaaaaaaaaaaaaaaaaaaaaaaa\nbbbbbbbbbbbbbbbbbbbbbbbbb\nend\n");
    ed.visible_cols = 20;
    ed.visible_rows = 10;

    // Click on screen row 4 should land on line 2.
    _ = ed.handleKey(.{ .mouse_click = .{ .row = 4, .col = 0 } });
    try std.testing.expectEqual(@as(usize, 2), ed.cursor.line);
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.col);
}

test "mouse click on wrap continuation clamps past line end" {
    var cfg = config_mod.Config.init();
    cfg.line_numbers = false;
    cfg.left_padding = 0;
    cfg.gutter_padding = 0;
    cfg.word_wrap = true;
    cfg.right_margin = 0;

    var ed = Editor.init(&cfg, std.testing.allocator);
    defer ed.deinit();

    // 25-char line wraps at width 20; continuation has 5 chars (cols 20-24).
    // Clicking at col 15 on the continuation should clamp to line length.
    try ed.buf.insert(0, "aaaaaaaaaaaaaaaaaaaaaaaaa\n");
    ed.visible_cols = 20;
    ed.visible_rows = 10;

    _ = ed.handleKey(.{ .mouse_click = .{ .row = 1, .col = 15 } });
    try std.testing.expectEqual(@as(usize, 0), ed.cursor.line);
    const info = ed.buf.getLine(0).?;
    try std.testing.expect(ed.cursor.col <= info.len);
}
