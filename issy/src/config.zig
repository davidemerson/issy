//! Editor configuration.
//!
//! Defines all configurable settings with sensible defaults. Supports loading
//! configuration from a file. Includes theme definitions for syntax colors.

const std = @import("std");
const term = @import("term.zig");

pub const Color = term.Color;

/// Theme colors for syntax highlighting and UI elements.
pub const Theme = struct {
    bg: Color = .{ .rgb = .{ .r = 0x1a, .g = 0x1b, .b = 0x26 } },
    fg: Color = .{ .rgb = .{ .r = 0xa9, .g = 0xb1, .b = 0xd6 } },
    comment: Color = .{ .rgb = .{ .r = 0x3b, .g = 0x42, .b = 0x61 } },
    keyword: Color = .{ .rgb = .{ .r = 0xbb, .g = 0x9a, .b = 0xf7 } },
    string: Color = .{ .rgb = .{ .r = 0x9e, .g = 0xce, .b = 0x6a } },
    number: Color = .{ .rgb = .{ .r = 0xa9, .g = 0xb1, .b = 0xd6 } },
    typ: Color = .{ .rgb = .{ .r = 0x7d, .g = 0xcf, .b = 0xff } },
    function: Color = .{ .rgb = .{ .r = 0xa9, .g = 0xb1, .b = 0xd6 } },
    operator: Color = .{ .rgb = .{ .r = 0x89, .g = 0xdd, .b = 0xff } },
    preprocessor: Color = .{ .rgb = .{ .r = 0xe0, .g = 0xaf, .b = 0x68 } },
    line_number: Color = .{ .rgb = .{ .r = 0x2a, .g = 0x2e, .b = 0x3f } },
    line_number_active: Color = .{ .rgb = .{ .r = 0x54, .g = 0x5c, .b = 0x7e } },
    cursor_line_bg: Color = .{ .rgb = .{ .r = 0x1e, .g = 0x20, .b = 0x30 } },
    status_bg: Color = .{ .rgb = .{ .r = 0x1a, .g = 0x1b, .b = 0x26 } },
    status_fg: Color = .{ .rgb = .{ .r = 0x3b, .g = 0x42, .b = 0x61 } },
    cursor: Color = .{ .rgb = .{ .r = 0xc0, .g = 0xca, .b = 0xf5 } },
    selection: Color = .{ .rgb = .{ .r = 0x28, .g = 0x34, .b = 0x57 } },
    trailing_ws: Color = .{ .rgb = .{ .r = 0x2a, .g = 0x1f, .b = 0x1f } },
    indent_mismatch: Color = .{ .rgb = .{ .r = 0x2a, .g = 0x1f, .b = 0x1f } },
};

/// Paper (light) theme.
pub const paper_theme = Theme{
    .bg = .{ .rgb = .{ .r = 0xfa, .g = 0xfa, .b = 0xfa } },
    .fg = .{ .rgb = .{ .r = 0x4a, .g = 0x4a, .b = 0x4a } },
    .comment = .{ .rgb = .{ .r = 0xc4, .g = 0xc4, .b = 0xc4 } },
    .keyword = .{ .rgb = .{ .r = 0x7c, .g = 0x3a, .b = 0xed } },
    .string = .{ .rgb = .{ .r = 0x16, .g = 0xa3, .b = 0x4a } },
    .number = .{ .rgb = .{ .r = 0x4a, .g = 0x4a, .b = 0x4a } },
    .typ = .{ .rgb = .{ .r = 0x4a, .g = 0x4a, .b = 0x4a } },
    .function = .{ .rgb = .{ .r = 0x4a, .g = 0x4a, .b = 0x4a } },
    .operator = .{ .rgb = .{ .r = 0x6b, .g = 0x72, .b = 0x80 } },
    .preprocessor = .{ .rgb = .{ .r = 0xb4, .g = 0x53, .b = 0x09 } },
    .line_number = .{ .rgb = .{ .r = 0xe0, .g = 0xe0, .b = 0xe0 } },
    .line_number_active = .{ .rgb = .{ .r = 0x9c, .g = 0xa3, .b = 0xaf } },
    .cursor_line_bg = .{ .rgb = .{ .r = 0xf5, .g = 0xf5, .b = 0xf5 } },
    .status_bg = .{ .rgb = .{ .r = 0xfa, .g = 0xfa, .b = 0xfa } },
    .status_fg = .{ .rgb = .{ .r = 0xc4, .g = 0xc4, .b = 0xc4 } },
    .cursor = .{ .rgb = .{ .r = 0x4a, .g = 0x4a, .b = 0x4a } },
    .selection = .{ .rgb = .{ .r = 0xe8, .g = 0xe0, .b = 0xff } },
    .trailing_ws = .{ .rgb = .{ .r = 0xff, .g = 0xf0, .b = 0xf0 } },
    .indent_mismatch = .{ .rgb = .{ .r = 0xff, .g = 0xf0, .b = 0xf0 } },
};

/// Print theme — used only for PDF output. White paper with ink-appropriate colors.
pub const PrintTheme = struct {
    fg: Color,
    keyword: Color,
    string: Color,
    comment: Color,
    number: Color,
    typ: Color,
    function: Color,
    operator: Color,
    preprocessor: Color,
    line_number: Color,
};

pub const print_theme = PrintTheme{
    .fg = .{ .rgb = .{ .r = 0x2e, .g = 0x2e, .b = 0x2e } },
    .keyword = .{ .rgb = .{ .r = 0x6d, .g = 0x28, .b = 0xd9 } },
    .string = .{ .rgb = .{ .r = 0x16, .g = 0x65, .b = 0x34 } },
    .comment = .{ .rgb = .{ .r = 0x9c, .g = 0xa3, .b = 0xaf } },
    .number = .{ .rgb = .{ .r = 0x2e, .g = 0x2e, .b = 0x2e } },
    .typ = .{ .rgb = .{ .r = 0x1e, .g = 0x40, .b = 0xaf } },
    .function = .{ .rgb = .{ .r = 0x2e, .g = 0x2e, .b = 0x2e } },
    .operator = .{ .rgb = .{ .r = 0x6b, .g = 0x72, .b = 0x80 } },
    .preprocessor = .{ .rgb = .{ .r = 0x92, .g = 0x40, .b = 0x0e } },
    .line_number = .{ .rgb = .{ .r = 0x99, .g = 0x99, .b = 0x99 } },
};

/// Complete editor configuration.
pub const Config = struct {
    tab_width: u8 = 4,
    expand_tabs: bool = true,
    line_numbers: bool = true,
    word_wrap: bool = true,
    auto_indent: bool = true,
    auto_close_brackets: bool = false,
    auto_detect_indent: bool = true,
    trailing_whitespace: bool = true,
    indent_mismatch: bool = true,
    scroll_margin: u8 = 5,

    // Visual design
    gutter_padding: u8 = 2,
    left_padding: u8 = 1,
    right_margin: u16 = 100,
    cursor_line_bg: bool = true,
    cursor_style: term.CursorShape = .bar,

    theme: Theme = .{},
    theme_name: [64]u8 = initThemeName("default"),
    theme_name_len: usize = 7,

    // Font / print
    font_file: [512]u8 = std.mem.zeroes([512]u8),
    font_file_len: usize = 0,
    font_size: f32 = 10.0,
    print_margin_top: f32 = 72.0,
    print_margin_bottom: f32 = 72.0,
    print_margin_left: f32 = 108.0,
    print_margin_right: f32 = 72.0,

    pub fn init() Config {
        return .{};
    }

    pub fn fontFilePath(self: *const Config) ?[]const u8 {
        if (self.font_file_len == 0) return null;
        return self.font_file[0..self.font_file_len];
    }

    pub fn getThemeName(self: *const Config) []const u8 {
        return self.theme_name[0..self.theme_name_len];
    }
};

fn initThemeName(comptime name: []const u8) [64]u8 {
    var buf: [64]u8 = std.mem.zeroes([64]u8);
    for (name, 0..) |c, i| buf[i] = c;
    return buf;
}

/// Load configuration from a file. If path is null, try default path.
pub fn load(allocator: std.mem.Allocator, path: ?[]const u8) Config {
    var cfg = Config.init();

    const actual_path = path orelse (defaultPath() orelse return cfg);
    _ = allocator;

    const file = std.fs.cwd().openFile(actual_path, .{}) catch return cfg;
    defer file.close();

    const stat = file.stat() catch return cfg;
    const file_size: usize = @intCast(stat.size);
    if (file_size == 0 or file_size > 65536) return cfg;

    var file_buf: [65536]u8 = undefined;
    const bytes_read = file.readAll(file_buf[0..file_size]) catch return cfg;
    const content = file_buf[0..bytes_read];

    var start: usize = 0;
    while (start < content.len) {
        const end = std.mem.indexOfScalarPos(u8, content, start, '\n') orelse content.len;
        const line = content[start..end];
        start = end + 1;

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        // [theme.name] sections
        if (trimmed[0] == '[') {
            if (std.mem.startsWith(u8, trimmed, "[theme.")) {
                if (std.mem.indexOfScalar(u8, trimmed, ']')) |end_bracket| {
                    const name = trimmed[7..end_bracket];
                    if (std.mem.eql(u8, name, "paper")) {
                        cfg.theme = paper_theme;
                        if (name.len <= 64) {
                            @memcpy(cfg.theme_name[0..name.len], name);
                            cfg.theme_name_len = name.len;
                        }
                    }
                }
            }
            continue;
        }

        // key = value
        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            var val = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

            // Strip quotes
            if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
                val = val[1 .. val.len - 1];
            }

            parseConfigKey(&cfg, key, val);
        }
    }

    return cfg;
}

fn parseConfigKey(cfg: *Config, key: []const u8, val: []const u8) void {
    if (std.mem.eql(u8, key, "tab_width")) {
        cfg.tab_width = std.fmt.parseInt(u8, val, 10) catch return;
    } else if (std.mem.eql(u8, key, "expand_tabs")) {
        cfg.expand_tabs = parseBool(val);
    } else if (std.mem.eql(u8, key, "line_numbers")) {
        cfg.line_numbers = parseBool(val);
    } else if (std.mem.eql(u8, key, "word_wrap")) {
        cfg.word_wrap = parseBool(val);
    } else if (std.mem.eql(u8, key, "auto_indent")) {
        cfg.auto_indent = parseBool(val);
    } else if (std.mem.eql(u8, key, "auto_close_brackets")) {
        cfg.auto_close_brackets = parseBool(val);
    } else if (std.mem.eql(u8, key, "auto_detect_indent")) {
        cfg.auto_detect_indent = parseBool(val);
    } else if (std.mem.eql(u8, key, "trailing_whitespace")) {
        cfg.trailing_whitespace = parseBool(val);
    } else if (std.mem.eql(u8, key, "indent_mismatch")) {
        cfg.indent_mismatch = parseBool(val);
    } else if (std.mem.eql(u8, key, "scroll_margin")) {
        cfg.scroll_margin = std.fmt.parseInt(u8, val, 10) catch return;
    } else if (std.mem.eql(u8, key, "gutter_padding")) {
        cfg.gutter_padding = std.fmt.parseInt(u8, val, 10) catch return;
    } else if (std.mem.eql(u8, key, "left_padding")) {
        cfg.left_padding = std.fmt.parseInt(u8, val, 10) catch return;
    } else if (std.mem.eql(u8, key, "right_margin")) {
        cfg.right_margin = std.fmt.parseInt(u16, val, 10) catch return;
    } else if (std.mem.eql(u8, key, "cursor_line_bg")) {
        cfg.cursor_line_bg = parseBool(val);
    } else if (std.mem.eql(u8, key, "cursor_style")) {
        if (std.mem.eql(u8, val, "bar")) cfg.cursor_style = .bar
        else if (std.mem.eql(u8, val, "block")) cfg.cursor_style = .block
        else if (std.mem.eql(u8, val, "underline")) cfg.cursor_style = .underline;
    } else if (std.mem.eql(u8, key, "font_file")) {
        if (val.len <= 512) {
            @memcpy(cfg.font_file[0..val.len], val);
            cfg.font_file_len = val.len;
        }
    } else if (std.mem.eql(u8, key, "font_size")) {
        cfg.font_size = std.fmt.parseFloat(f32, val) catch return;
    } else if (std.mem.eql(u8, key, "print_margin_top")) {
        cfg.print_margin_top = std.fmt.parseFloat(f32, val) catch return;
    } else if (std.mem.eql(u8, key, "print_margin_bottom")) {
        cfg.print_margin_bottom = std.fmt.parseFloat(f32, val) catch return;
    } else if (std.mem.eql(u8, key, "print_margin_left")) {
        cfg.print_margin_left = std.fmt.parseFloat(f32, val) catch return;
    } else if (std.mem.eql(u8, key, "print_margin_right")) {
        cfg.print_margin_right = std.fmt.parseFloat(f32, val) catch return;
    }
    // Theme color keys
    else if (std.mem.startsWith(u8, key, "bg")) {
        if (parseHexColor(val)) |c| cfg.theme.bg = c;
    } else if (std.mem.eql(u8, key, "fg")) {
        if (parseHexColor(val)) |c| cfg.theme.fg = c;
    } else if (std.mem.eql(u8, key, "comment")) {
        if (parseHexColor(val)) |c| cfg.theme.comment = c;
    } else if (std.mem.eql(u8, key, "keyword")) {
        if (parseHexColor(val)) |c| cfg.theme.keyword = c;
    } else if (std.mem.eql(u8, key, "string_color")) {
        if (parseHexColor(val)) |c| cfg.theme.string = c;
    } else if (std.mem.eql(u8, key, "number_color")) {
        if (parseHexColor(val)) |c| cfg.theme.number = c;
    } else if (std.mem.eql(u8, key, "type_color")) {
        if (parseHexColor(val)) |c| cfg.theme.typ = c;
    } else if (std.mem.eql(u8, key, "function_color")) {
        if (parseHexColor(val)) |c| cfg.theme.function = c;
    } else if (std.mem.eql(u8, key, "operator_color")) {
        if (parseHexColor(val)) |c| cfg.theme.operator = c;
    } else if (std.mem.eql(u8, key, "preprocessor_color")) {
        if (parseHexColor(val)) |c| cfg.theme.preprocessor = c;
    } else if (std.mem.eql(u8, key, "line_number_color")) {
        if (parseHexColor(val)) |c| cfg.theme.line_number = c;
    } else if (std.mem.eql(u8, key, "line_number_active")) {
        if (parseHexColor(val)) |c| cfg.theme.line_number_active = c;
    } else if (std.mem.eql(u8, key, "cursor_line_color")) {
        if (parseHexColor(val)) |c| cfg.theme.cursor_line_bg = c;
    } else if (std.mem.eql(u8, key, "selection_color")) {
        if (parseHexColor(val)) |c| cfg.theme.selection = c;
    } else if (std.mem.eql(u8, key, "trailing_ws_color")) {
        if (parseHexColor(val)) |c| cfg.theme.trailing_ws = c;
    } else if (std.mem.eql(u8, key, "indent_mismatch_color")) {
        if (parseHexColor(val)) |c| cfg.theme.indent_mismatch = c;
    }
}

fn parseBool(val: []const u8) bool {
    return std.mem.eql(u8, val, "true") or std.mem.eql(u8, val, "1") or std.mem.eql(u8, val, "yes");
}

/// Parse "#rrggbb" hex color.
pub fn parseHexColor(s: []const u8) ?Color {
    if (s.len != 7 or s[0] != '#') return null;
    const r = std.fmt.parseInt(u8, s[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, s[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, s[5..7], 16) catch return null;
    return .{ .rgb = .{ .r = r, .g = g, .b = b } };
}

/// Return default config path, or null if not available.
pub fn defaultPath() ?[]const u8 {
    // Try ~/.issyrc on POSIX
    if (std.process.getEnvVarOwned(std.heap.page_allocator, "HOME")) |home| {
        defer std.heap.page_allocator.free(home);
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.issyrc", .{home}) catch return null;
        if (std.fs.cwd().access(path, .{})) |_| {
            // File exists but we can't return a temp buffer
            return null; // Caller should construct the path
        } else |_| {
            return null;
        }
    } else |_| {
        return null;
    }
}

// ── Tests ──

test "default config has sane values" {
    const cfg = Config.init();
    try std.testing.expectEqual(@as(u8, 4), cfg.tab_width);
    try std.testing.expect(cfg.expand_tabs);
    try std.testing.expect(cfg.line_numbers);
    try std.testing.expectEqual(@as(u16, 100), cfg.right_margin);
    try std.testing.expectEqualSlices(u8, "default", cfg.getThemeName());
}

test "parseHexColor valid" {
    const c = parseHexColor("#ff8800").?;
    switch (c) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0xff), rgb.r);
            try std.testing.expectEqual(@as(u8, 0x88), rgb.g);
            try std.testing.expectEqual(@as(u8, 0x00), rgb.b);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseHexColor invalid" {
    try std.testing.expectEqual(@as(?Color, null), parseHexColor("ff8800"));
    try std.testing.expectEqual(@as(?Color, null), parseHexColor("#gg0000"));
    try std.testing.expectEqual(@as(?Color, null), parseHexColor("#fff"));
}

test "paper theme has light bg" {
    const c = paper_theme.bg;
    switch (c) {
        .rgb => |rgb| {
            try std.testing.expectEqual(@as(u8, 0xfa), rgb.r);
        },
        else => return error.TestUnexpectedResult,
    }
}
