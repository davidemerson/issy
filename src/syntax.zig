//! Syntax highlighting engine.
//!
//! Provides language detection by file extension and line-by-line tokenization
//! for syntax highlighting. Uses a state machine tokenizer with no allocations
//! in the hot path.

const std = @import("std");

pub const TokenType = enum {
    normal,
    keyword1,
    keyword2,
    comment,
    string,
    number,
    typ,
    function,
    operator,
    preprocessor,
};

pub const Token = struct {
    start: usize,
    end: usize,
    token_type: TokenType,
};

pub const State = enum {
    normal,
    comment_multi,
    /// Inside a Python """...""" string.
    string_triple_dq,
    /// Inside a Python '''...''' string.
    string_triple_sq,
    /// Inside a JS/TS `...` template literal.
    string_backtick,
};

/// Returns the closing delimiter for a multi-line string state, or null
/// when the state isn't a string continuation.
fn stringStateDelim(s: State) ?[]const u8 {
    return switch (s) {
        .string_triple_dq => "\"\"\"",
        .string_triple_sq => "'''",
        .string_backtick => "`",
        else => null,
    };
}

pub const Language = struct {
    name: []const u8,
    extensions: []const []const u8,
    keywords1: []const []const u8,
    keywords2: []const []const u8,
    single_line_comment: ?[]const u8,
    multi_comment_start: ?[]const u8,
    multi_comment_end: ?[]const u8,
    string_delimiters: []const u8,
    has_char_literals: bool,
    preprocessor_prefix: ?u8,
    /// Optional leading character that introduces a "command" token
    /// (`\` in TeX/LaTeX). When set, a run of `<prefix><letter>+` is
    /// tokenized as a single keyword1, regardless of the keyword list.
    /// A bare prefix with no following letter falls through to the
    /// operator/skip path.
    command_prefix: ?u8 = null,
    /// Python-style """ / ''' strings that may span lines.
    triple_quote_strings: bool = false,
    /// JS/TS template literals: `...` strings that may span lines.
    backtick_multiline: bool = false,
    /// Zig-style line strings: this prefix makes the rest of the line a
    /// string literal (`\\` in Zig).
    line_string_prefix: ?[]const u8 = null,
};

/// Detect the language for a file based on its name/extension.
pub fn detect(filename: []const u8) ?*const Language {
    // Check for exact basename matches first (Makefile, etc.)
    const basename = if (std.mem.lastIndexOfScalar(u8, filename, '/')) |idx|
        filename[idx + 1 ..]
    else
        filename;

    for (&languages) |*lang| {
        for (lang.extensions) |ext| {
            if (ext[0] != '.') {
                // Exact name match
                if (std.mem.eql(u8, basename, ext)) return lang;
            }
        }
    }

    // Check extension
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot| {
        const ext = filename[dot..];
        for (&languages) |*lang| {
            for (lang.extensions) |lang_ext| {
                if (lang_ext[0] == '.' and std.mem.eql(u8, ext, lang_ext)) return lang;
            }
        }
    }

    return null;
}

/// Tokenize a single line. Returns slice of tokens written into result_buf.
/// State carries multi-line comment/string state between lines.
pub fn tokenizeLine(lang: *const Language, line: []const u8, state: *State, result_buf: []Token) []Token {
    var count: usize = 0;
    var i: usize = 0;

    // Continuing multi-line comment from previous line
    if (state.* == .comment_multi) {
        const start = i;
        if (lang.multi_comment_end) |mce| {
            while (i < line.len) {
                if (i + mce.len <= line.len and std.mem.eql(u8, line[i..][0..mce.len], mce)) {
                    i += mce.len;
                    state.* = .normal;
                    break;
                }
                i += 1;
            }
        } else {
            i = line.len;
        }
        if (i > start) {
            if (count < result_buf.len) {
                result_buf[count] = .{ .start = start, .end = i, .token_type = .comment };
                count += 1;
            }
        }
        if (state.* == .comment_multi) {
            return result_buf[0..count];
        }
    }

    // Continuing multi-line string (triple-quoted or template literal)
    // from a previous line.
    if (stringStateDelim(state.*)) |delim| {
        const start = i;
        while (i < line.len) {
            if (line[i] == '\\') {
                i += 2;
                continue;
            }
            if (i + delim.len <= line.len and std.mem.eql(u8, line[i..][0..delim.len], delim)) {
                i += delim.len;
                state.* = .normal;
                break;
            }
            i += 1;
        }
        if (i > line.len) i = line.len; // escape at EOL can overshoot
        if (i > start) {
            if (count < result_buf.len) {
                result_buf[count] = .{ .start = start, .end = i, .token_type = .string };
                count += 1;
            }
        }
        if (state.* != .normal) {
            return result_buf[0..count];
        }
    }

    while (i < line.len) {
        // Skip whitespace
        if (line[i] == ' ' or line[i] == '\t') {
            i += 1;
            continue;
        }

        // Single-line comment
        if (lang.single_line_comment) |slc| {
            if (i + slc.len <= line.len and std.mem.eql(u8, line[i..][0..slc.len], slc)) {
                if (count < result_buf.len) {
                    result_buf[count] = .{ .start = i, .end = line.len, .token_type = .comment };
                    count += 1;
                }
                return result_buf[0..count];
            }
        }

        // Multi-line comment start
        if (lang.multi_comment_start) |mcs| {
            if (i + mcs.len <= line.len and std.mem.eql(u8, line[i..][0..mcs.len], mcs)) {
                const start = i;
                i += mcs.len;
                if (lang.multi_comment_end) |mce| {
                    var found = false;
                    while (i < line.len) {
                        if (i + mce.len <= line.len and std.mem.eql(u8, line[i..][0..mce.len], mce)) {
                            i += mce.len;
                            found = true;
                            break;
                        }
                        i += 1;
                    }
                    if (!found) state.* = .comment_multi;
                }
                if (count < result_buf.len) {
                    result_buf[count] = .{ .start = start, .end = i, .token_type = .comment };
                    count += 1;
                }
                continue;
            }
        }

        // Preprocessor
        if (lang.preprocessor_prefix) |pp| {
            if (line[i] == pp) {
                if (count < result_buf.len) {
                    result_buf[count] = .{ .start = i, .end = line.len, .token_type = .preprocessor };
                    count += 1;
                }
                return result_buf[0..count];
            }
        }

        // Command prefix (e.g. `\` in TeX). A run of `<prefix><letter>+`
        // becomes a single keyword1 token covering both the prefix and
        // the name. A bare prefix with no letter following falls through
        // to the generic operator/skip path below.
        if (lang.command_prefix) |cp| {
            if (line[i] == cp and i + 1 < line.len and isAlpha(line[i + 1])) {
                const start = i;
                i += 1;
                while (i < line.len and isAlpha(line[i])) : (i += 1) {}
                if (count < result_buf.len) {
                    result_buf[count] = .{ .start = start, .end = i, .token_type = .keyword1 };
                    count += 1;
                }
                continue;
            }
        }

        // Zig-style line string: `\\` makes the rest of the line a string.
        if (lang.line_string_prefix) |lsp| {
            if (i + lsp.len <= line.len and std.mem.eql(u8, line[i..][0..lsp.len], lsp)) {
                if (count < result_buf.len) {
                    result_buf[count] = .{ .start = i, .end = line.len, .token_type = .string };
                    count += 1;
                }
                return result_buf[0..count];
            }
        }

        // Triple-quoted strings (Python). May span lines via State.
        if (lang.triple_quote_strings and i + 3 <= line.len and
            (std.mem.eql(u8, line[i..][0..3], "\"\"\"") or std.mem.eql(u8, line[i..][0..3], "'''")))
        {
            const dq = line[i] == '"';
            const delim: []const u8 = if (dq) "\"\"\"" else "'''";
            const start = i;
            i += 3;
            var closed = false;
            while (i < line.len) {
                if (line[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (i + 3 <= line.len and std.mem.eql(u8, line[i..][0..3], delim)) {
                    i += 3;
                    closed = true;
                    break;
                }
                i += 1;
            }
            if (i > line.len) i = line.len;
            if (!closed) state.* = if (dq) .string_triple_dq else .string_triple_sq;
            if (count < result_buf.len) {
                result_buf[count] = .{ .start = start, .end = i, .token_type = .string };
                count += 1;
            }
            continue;
        }

        // Template literals (JS/TS): `...` — may span lines via State.
        if (lang.backtick_multiline and line[i] == '`') {
            const start = i;
            i += 1;
            var closed = false;
            while (i < line.len) {
                if (line[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (line[i] == '`') {
                    i += 1;
                    closed = true;
                    break;
                }
                i += 1;
            }
            if (i > line.len) i = line.len;
            if (!closed) state.* = .string_backtick;
            if (count < result_buf.len) {
                result_buf[count] = .{ .start = start, .end = i, .token_type = .string };
                count += 1;
            }
            continue;
        }

        // String
        if (isStringDelimiter(lang, line[i])) {
            const delim = line[i];
            const start = i;
            i += 1;
            while (i < line.len) {
                if (line[i] == '\\') {
                    i += 2;
                    continue;
                }
                if (line[i] == delim) {
                    i += 1;
                    break;
                }
                i += 1;
            }
            if (i > line.len) i = line.len; // escape at EOL can overshoot
            if (count < result_buf.len) {
                result_buf[count] = .{ .start = start, .end = i, .token_type = .string };
                count += 1;
            }
            continue;
        }

        // Number. Radix prefixes constrain the digit set (a plain decimal
        // no longer absorbs stray a-f letters), and decimal literals
        // accept an e/E exponent with optional sign.
        if (isDigit(line[i]) or (line[i] == '.' and i + 1 < line.len and isDigit(line[i + 1]))) {
            const start = i;
            if (line[i] == '0' and i + 1 < line.len and (line[i + 1] == 'x' or line[i + 1] == 'X')) {
                i += 2;
                while (i < line.len and (isHexDigit(line[i]) or line[i] == '_' or line[i] == '.')) i += 1;
            } else if (line[i] == '0' and i + 1 < line.len and (line[i + 1] == 'b' or line[i + 1] == 'B')) {
                i += 2;
                while (i < line.len and (line[i] == '0' or line[i] == '1' or line[i] == '_')) i += 1;
            } else if (line[i] == '0' and i + 1 < line.len and (line[i + 1] == 'o' or line[i + 1] == 'O')) {
                i += 2;
                while (i < line.len and ((line[i] >= '0' and line[i] <= '7') or line[i] == '_')) i += 1;
            } else {
                while (i < line.len and (isDigit(line[i]) or line[i] == '.' or line[i] == '_')) i += 1;
                if (i < line.len and (line[i] == 'e' or line[i] == 'E')) {
                    var j = i + 1;
                    if (j < line.len and (line[j] == '+' or line[j] == '-')) j += 1;
                    if (j < line.len and isDigit(line[j])) {
                        i = j;
                        while (i < line.len and (isDigit(line[i]) or line[i] == '_')) i += 1;
                    }
                }
            }
            if (count < result_buf.len) {
                result_buf[count] = .{ .start = start, .end = i, .token_type = .number };
                count += 1;
            }
            continue;
        }

        // Identifier (keyword/function/type check)
        if (isIdentStart(line[i])) {
            const start = i;
            while (i < line.len and isIdentChar(line[i])) {
                i += 1;
            }
            const word = line[start..i];
            var tt: TokenType = .normal;

            if (isInList(word, lang.keywords1)) {
                tt = .keyword1;
            } else if (isInList(word, lang.keywords2)) {
                tt = .keyword2;
            } else if (i < line.len and line[i] == '(') {
                tt = .function;
            } else if (word.len > 0 and word[0] >= 'A' and word[0] <= 'Z') {
                tt = .typ;
            }

            if (count < result_buf.len) {
                result_buf[count] = .{ .start = start, .end = i, .token_type = tt };
                count += 1;
            }
            continue;
        }

        // Operator
        if (isOperator(line[i])) {
            if (count < result_buf.len) {
                result_buf[count] = .{ .start = i, .end = i + 1, .token_type = .operator };
                count += 1;
            }
            i += 1;
            continue;
        }

        i += 1;
    }

    return result_buf[0..count];
}

fn isStringDelimiter(lang: *const Language, c: u8) bool {
    for (lang.string_delimiters) |d| {
        if (c == d) return true;
    }
    return false;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn isAlpha(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c == '@';
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn isOperator(c: u8) bool {
    return switch (c) {
        '+', '-', '*', '/', '%', '=', '<', '>', '!', '&', '|', '^', '~', '?', ':', ';', ',', '.' => true,
        else => false,
    };
}

fn isInList(word: []const u8, list: []const []const u8) bool {
    for (list) |kw| {
        if (std.mem.eql(u8, word, kw)) return true;
    }
    return false;
}

// ── Language definitions ──

const c_keywords1 = [_][]const u8{
    "auto",     "break",     "case",           "const",         "continue", "default",
    "do",       "else",      "enum",           "extern",        "for",      "goto",
    "if",       "inline",    "register",       "restrict",      "return",   "sizeof",
    "static",   "struct",    "switch",         "typedef",       "union",    "volatile",
    "while",    "_Alignas",  "_Alignof",       "_Atomic",       "_Bool",    "_Complex",
    "_Generic", "_Noreturn", "_Static_assert", "_Thread_local",
};

const c_keywords2 = [_][]const u8{
    "char",     "double",  "float",    "int",      "long",     "short",   "signed",
    "unsigned", "void",    "size_t",   "ssize_t",  "int8_t",   "int16_t", "int32_t",
    "int64_t",  "uint8_t", "uint16_t", "uint32_t", "uint64_t", "bool",    "true",
    "false",    "NULL",
};

const cpp_keywords1 = [_][]const u8{
    "alignas",    "alignof",  "and",           "and_eq",           "asm",       "auto",
    "bitand",     "bitor",    "break",         "case",             "catch",     "class",
    "compl",      "concept",  "const",         "consteval",        "constexpr", "constinit",
    "const_cast", "continue", "co_await",      "co_return",        "co_yield",  "decltype",
    "default",    "delete",   "do",            "dynamic_cast",     "else",      "enum",
    "explicit",   "export",   "extern",        "for",              "friend",    "goto",
    "if",         "inline",   "mutable",       "namespace",        "new",       "noexcept",
    "not",        "not_eq",   "operator",      "or",               "or_eq",     "private",
    "protected",  "public",   "register",      "reinterpret_cast", "requires",  "return",
    "sizeof",     "static",   "static_assert", "static_cast",      "struct",    "switch",
    "template",   "this",     "throw",         "try",              "typedef",   "typeid",
    "typename",   "union",    "using",         "virtual",          "volatile",  "while",
    "xor",        "xor_eq",
};

const cpp_keywords2 = [_][]const u8{
    "bool",   "char",    "char8_t", "char16_t", "char32_t",   "double",
    "float",  "int",     "long",    "short",    "signed",     "unsigned",
    "void",   "wchar_t", "nullptr", "true",     "false",      "string",
    "vector", "map",     "set",     "array",    "unique_ptr", "shared_ptr",
};

const zig_keywords1 = [_][]const u8{
    "addrspace",   "align",       "allowzero", "and",         "anyframe",
    "anytype",     "asm",         "async",     "await",       "break",
    "callconv",    "catch",       "comptime",  "const",       "continue",
    "defer",       "else",        "enum",      "errdefer",    "error",
    "export",      "extern",      "fn",        "for",         "if",
    "inline",      "linksection", "noalias",   "nosuspend",   "opaque",
    "or",          "orelse",      "packed",    "pub",         "resume",
    "return",      "struct",      "suspend",   "switch",      "test",
    "threadlocal", "try",         "union",     "unreachable", "var",
    "volatile",    "while",
};

const zig_keywords2 = [_][]const u8{
    "bool",   "f16",        "f32",    "f64",      "f80",
    "f128",   "i8",         "i16",    "i32",      "i64",
    "i128",   "isize",      "u8",     "u16",      "u32",
    "u64",    "u128",       "usize",  "c_short",  "c_int",
    "c_long", "c_longlong", "c_char", "anyerror", "void",
    "null",   "undefined",  "true",   "false",    "type",
};

const python_keywords1 = [_][]const u8{
    "False",  "None",     "True",  "and",    "as",       "assert",
    "async",  "await",    "break", "class",  "continue", "def",
    "del",    "elif",     "else",  "except", "finally",  "for",
    "from",   "global",   "if",    "import", "in",       "is",
    "lambda", "nonlocal", "not",   "or",     "pass",     "raise",
    "return", "try",      "while", "with",   "yield",
};

const python_keywords2 = [_][]const u8{
    "int",      "float",        "str",         "bool",   "list",     "dict",       "set",        "tuple",
    "bytes",    "bytearray",    "range",       "type",   "object",   "print",      "len",        "enumerate",
    "zip",      "map",          "filter",      "sorted", "reversed", "isinstance", "issubclass", "super",
    "property", "staticmethod", "classmethod", "self",   "cls",
};

const js_keywords1 = [_][]const u8{
    "break",    "case",       "catch",  "class",    "const", "continue",
    "debugger", "default",    "delete", "do",       "else",  "export",
    "extends",  "finally",    "for",    "function", "if",    "import",
    "in",       "instanceof", "let",    "new",      "of",    "return",
    "static",   "super",      "switch", "this",     "throw", "try",
    "typeof",   "var",        "void",   "while",    "with",  "yield",
    "async",    "await",
};

const js_keywords2 = [_][]const u8{
    "true",     "false",   "null",    "undefined", "NaN",
    "Infinity", "Array",   "Boolean", "Date",      "Error",
    "Function", "JSON",    "Map",     "Math",      "Number",
    "Object",   "Promise", "Proxy",   "RegExp",    "Set",
    "String",   "Symbol",  "WeakMap", "WeakSet",   "console",
};

const ts_keywords1 = js_keywords1 ++ [_][]const u8{
    "abstract",  "as",       "declare", "enum",      "implements",
    "interface", "keyof",    "module",  "namespace", "readonly",
    "type",      "override",
};

const ts_keywords2 = js_keywords2 ++ [_][]const u8{
    "any",     "boolean", "never",  "number", "string",
    "unknown", "void",    "bigint",
};

const rust_keywords1 = [_][]const u8{
    "as",     "async",  "await",  "break",  "const",  "continue",
    "crate",  "dyn",    "else",   "enum",   "extern", "fn",
    "for",    "if",     "impl",   "in",     "let",    "loop",
    "match",  "mod",    "move",   "mut",    "pub",    "ref",
    "return", "self",   "static", "struct", "super",  "trait",
    "type",   "unsafe", "use",    "where",  "while",  "yield",
};

const rust_keywords2 = [_][]const u8{
    "bool", "char", "f32",    "f64",    "i8",    "i16",
    "i32",  "i64",  "i128",   "isize",  "str",   "u8",
    "u16",  "u32",  "u64",    "u128",   "usize", "String",
    "Vec",  "Box",  "Option", "Result", "Some",  "None",
    "Ok",   "Err",  "Self",   "true",   "false",
};

const go_keywords1 = [_][]const u8{
    "break",     "case",   "chan",    "const",       "continue",
    "default",   "defer",  "else",    "fallthrough", "for",
    "func",      "go",     "goto",    "if",          "import",
    "interface", "map",    "package", "range",       "return",
    "select",    "struct", "switch",  "type",        "var",
};

const go_keywords2 = [_][]const u8{
    "bool",    "byte",    "complex64", "complex128", "error",
    "float32", "float64", "int",       "int8",       "int16",
    "int32",   "int64",   "rune",      "string",     "uint",
    "uint8",   "uint16",  "uint32",    "uint64",     "uintptr",
    "true",    "false",   "nil",       "iota",       "append",
    "cap",     "close",   "copy",      "delete",     "len",
    "make",    "new",     "panic",     "print",      "println",
    "recover",
};

const shell_keywords1 = [_][]const u8{
    "if",   "then",     "else",   "elif",  "fi",     "case",
    "esac", "for",      "while",  "until", "do",     "done",
    "in",   "function", "select", "time",  "coproc",
};

const shell_keywords2 = [_][]const u8{
    "echo",  "read",    "printf",  "local", "export", "source",
    "exit",  "return",  "shift",   "set",   "unset",  "eval",
    "exec",  "trap",    "cd",      "pwd",   "test",   "true",
    "false", "declare", "typeset",
};

const html_keywords1 = [_][]const u8{
    "html",   "head",  "body",    "div",     "span",  "p",
    "a",      "img",   "ul",      "ol",      "li",    "table",
    "tr",     "td",    "th",      "form",    "input", "button",
    "script", "style", "link",    "meta",    "title", "header",
    "footer", "nav",   "section", "article", "aside", "main",
    "h1",     "h2",    "h3",      "h4",      "h5",    "h6",
};

const html_keywords2 = [_][]const u8{
    "class",  "id",    "src",     "href",    "alt",    "type",
    "name",   "value", "style",   "width",   "height", "action",
    "method", "rel",   "content", "charset",
};

const css_keywords1 = [_][]const u8{
    "color",           "background", "border",   "margin",  "padding",
    "font",            "display",    "position", "width",   "height",
    "top",             "left",       "right",    "bottom",  "float",
    "clear",           "overflow",   "z-index",  "opacity", "transform",
    "transition",      "animation",  "flex",     "grid",    "align-items",
    "justify-content",
};

const css_keywords2 = [_][]const u8{
    "none",     "block",   "inline",  "flex",   "grid",
    "auto",     "inherit", "initial", "unset",  "absolute",
    "relative", "fixed",   "sticky",  "hidden", "visible",
    "solid",    "dashed",  "dotted",  "center", "left",
    "right",    "top",     "bottom",
};

const ruby_keywords1 = [_][]const u8{
    "alias", "and",   "begin",    "break",  "case",   "class",
    "def",   "do",    "else",     "elsif",  "end",    "ensure",
    "for",   "if",    "in",       "module", "next",   "not",
    "or",    "redo",  "rescue",   "retry",  "return", "self",
    "super", "then",  "undef",    "unless", "until",  "when",
    "while", "yield", "defined?",
};

const ruby_keywords2 = [_][]const u8{
    "true",             "false",         "nil",         "require",
    "require_relative", "attr_accessor", "attr_reader", "attr_writer",
    "puts",             "print",         "new",         "lambda",
    "proc",             "raise",         "include",     "extend",
    "private",          "public",        "protected",   "module_function",
};

const java_keywords1 = [_][]const u8{
    "abstract",   "assert",       "break",     "case",       "catch",
    "class",      "const",        "continue",  "default",    "do",
    "else",       "enum",         "extends",   "final",      "finally",
    "for",        "goto",         "if",        "implements", "import",
    "instanceof", "interface",    "native",    "new",        "package",
    "permits",    "private",      "protected", "public",     "record",
    "return",     "sealed",       "static",    "strictfp",   "super",
    "switch",     "synchronized", "this",      "throw",      "throws",
    "transient",  "try",          "var",       "volatile",   "while",
    "yield",
};

const java_keywords2 = [_][]const u8{
    "boolean", "byte",      "char",    "double",   "float",
    "int",     "long",      "short",   "void",     "true",
    "false",   "null",      "String",  "Integer",  "Long",
    "Double",  "Boolean",   "Object",  "List",     "Map",
    "Set",     "ArrayList", "HashMap", "Optional",
};

const dockerfile_keywords1 = [_][]const u8{
    "FROM",        "RUN",     "CMD",        "LABEL",      "EXPOSE",
    "ENV",         "ADD",     "COPY",       "ENTRYPOINT", "VOLUME",
    "USER",        "WORKDIR", "ARG",        "ONBUILD",    "STOPSIGNAL",
    "HEALTHCHECK", "SHELL",   "MAINTAINER", "AS",
};

const empty_keywords = [_][]const u8{};

pub const languages = [_]Language{
    .{
        .name = "C",
        .extensions = &.{ ".c", ".h" },
        .keywords1 = &c_keywords1,
        .keywords2 = &c_keywords2,
        .single_line_comment = "//",
        .multi_comment_start = "/*",
        .multi_comment_end = "*/",
        .string_delimiters = "\"'",
        .has_char_literals = true,
        .preprocessor_prefix = '#',
    },
    .{
        .name = "C++",
        .extensions = &.{ ".cpp", ".cc", ".cxx", ".hpp", ".hxx" },
        .keywords1 = &cpp_keywords1,
        .keywords2 = &cpp_keywords2,
        .single_line_comment = "//",
        .multi_comment_start = "/*",
        .multi_comment_end = "*/",
        .string_delimiters = "\"'",
        .has_char_literals = true,
        .preprocessor_prefix = '#',
    },
    .{
        .name = "Zig",
        .extensions = &.{".zig"},
        .keywords1 = &zig_keywords1,
        .keywords2 = &zig_keywords2,
        .single_line_comment = "//",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"",
        .has_char_literals = false,
        .preprocessor_prefix = null,
        .line_string_prefix = "\\\\",
    },
    .{
        .name = "Python",
        .extensions = &.{".py"},
        .keywords1 = &python_keywords1,
        .keywords2 = &python_keywords2,
        .single_line_comment = "#",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
        .triple_quote_strings = true,
    },
    .{
        .name = "JavaScript",
        .extensions = &.{ ".js", ".mjs", ".jsx" },
        .keywords1 = &js_keywords1,
        .keywords2 = &js_keywords2,
        .single_line_comment = "//",
        .multi_comment_start = "/*",
        .multi_comment_end = "*/",
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
        .backtick_multiline = true,
    },
    .{
        .name = "TypeScript",
        .extensions = &.{ ".ts", ".tsx" },
        .keywords1 = &ts_keywords1,
        .keywords2 = &ts_keywords2,
        .single_line_comment = "//",
        .multi_comment_start = "/*",
        .multi_comment_end = "*/",
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
        .backtick_multiline = true,
    },
    .{
        .name = "Rust",
        .extensions = &.{".rs"},
        .keywords1 = &rust_keywords1,
        .keywords2 = &rust_keywords2,
        .single_line_comment = "//",
        .multi_comment_start = "/*",
        .multi_comment_end = "*/",
        .string_delimiters = "\"",
        .has_char_literals = true,
        .preprocessor_prefix = null,
    },
    .{
        .name = "Go",
        .extensions = &.{".go"},
        .keywords1 = &go_keywords1,
        .keywords2 = &go_keywords2,
        .single_line_comment = "//",
        .multi_comment_start = "/*",
        .multi_comment_end = "*/",
        .string_delimiters = "\"'`",
        .has_char_literals = true,
        .preprocessor_prefix = null,
    },
    .{
        .name = "Shell",
        // Dotfiles like .bashrc match through the extension path: the
        // leading dot of the basename is the last '.' in the filename,
        // so the whole basename arrives here as the "extension".
        .extensions = &.{ ".sh", ".bash", ".zsh", ".ksh", ".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".kshrc" },
        .keywords1 = &shell_keywords1,
        .keywords2 = &shell_keywords2,
        .single_line_comment = "#",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "HTML",
        .extensions = &.{ ".html", ".htm" },
        .keywords1 = &html_keywords1,
        .keywords2 = &html_keywords2,
        .single_line_comment = null,
        .multi_comment_start = "<!--",
        .multi_comment_end = "-->",
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "CSS",
        .extensions = &.{".css"},
        .keywords1 = &css_keywords1,
        .keywords2 = &css_keywords2,
        .single_line_comment = null,
        .multi_comment_start = "/*",
        .multi_comment_end = "*/",
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "JSON",
        .extensions = &.{".json"},
        .keywords1 = &[_][]const u8{ "true", "false", "null" },
        .keywords2 = &empty_keywords,
        .single_line_comment = null,
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "YAML",
        .extensions = &.{ ".yml", ".yaml" },
        .keywords1 = &[_][]const u8{ "true", "false", "null", "yes", "no" },
        .keywords2 = &empty_keywords,
        .single_line_comment = "#",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "TOML",
        .extensions = &.{".toml"},
        .keywords1 = &[_][]const u8{ "true", "false" },
        .keywords2 = &empty_keywords,
        .single_line_comment = "#",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "Makefile",
        .extensions = &.{ "Makefile", "makefile", "GNUmakefile", ".mk" },
        .keywords1 = &[_][]const u8{
            "ifeq",   "ifneq", "ifdef",   "ifndef",   "else",   "endif",
            "define", "endef", "include", "override", "export", "unexport",
            "vpath",
        },
        .keywords2 = &[_][]const u8{
            "subst",      "patsubst",  "strip",  "findstring", "filter",
            "filter-out", "sort",      "word",   "words",      "firstword",
            "wildcard",   "dir",       "notdir", "suffix",     "basename",
            "addsuffix",  "addprefix", "join",   "realpath",   "abspath",
            "shell",      "foreach",   "call",   "eval",       "origin",
            "error",      "warning",   "info",
        },
        .single_line_comment = "#",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "Ruby",
        .extensions = &.{ ".rb", ".rake", "Rakefile", "Gemfile" },
        .keywords1 = &ruby_keywords1,
        .keywords2 = &ruby_keywords2,
        .single_line_comment = "#",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "Java",
        .extensions = &.{".java"},
        .keywords1 = &java_keywords1,
        .keywords2 = &java_keywords2,
        .single_line_comment = "//",
        .multi_comment_start = "/*",
        .multi_comment_end = "*/",
        .string_delimiters = "\"'",
        .has_char_literals = true,
        .preprocessor_prefix = null,
    },
    .{
        .name = "Dockerfile",
        .extensions = &.{ "Dockerfile", "Containerfile" },
        .keywords1 = &dockerfile_keywords1,
        .keywords2 = &empty_keywords,
        .single_line_comment = "#",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "\"'",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "Markdown",
        .extensions = &.{".md"},
        .keywords1 = &empty_keywords,
        .keywords2 = &empty_keywords,
        .single_line_comment = null,
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "",
        .has_char_literals = false,
        .preprocessor_prefix = null,
    },
    .{
        .name = "TeX",
        .extensions = &.{ ".tex", ".ltx", ".sty", ".cls", ".bib", ".dtx" },
        .keywords1 = &empty_keywords, // commands are recognized via command_prefix
        .keywords2 = &empty_keywords,
        .single_line_comment = "%",
        .multi_comment_start = null,
        .multi_comment_end = null,
        .string_delimiters = "",
        .has_char_literals = false,
        .preprocessor_prefix = null,
        .command_prefix = '\\',
    },
};

// ── Tests ──

test "detect C by extension" {
    const lang = detect("hello.c").?;
    try std.testing.expectEqualSlices(u8, "C", lang.name);
}

test "detect Zig by extension" {
    const lang = detect("main.zig").?;
    try std.testing.expectEqualSlices(u8, "Zig", lang.name);
}

test "detect Python by extension" {
    const lang = detect("script.py").?;
    try std.testing.expectEqualSlices(u8, "Python", lang.name);
}

test "detect Makefile by name" {
    const lang = detect("Makefile").?;
    try std.testing.expectEqualSlices(u8, "Makefile", lang.name);
}

test "detect unknown returns null" {
    try std.testing.expectEqual(@as(?*const Language, null), detect("file.xyz"));
}

test "tokenize C snippet" {
    const lang = detect("test.c").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const line = "#include <stdio.h>";
    const tokens = tokenizeLine(lang, line, &state, &buf);
    try std.testing.expect(tokens.len > 0);
    try std.testing.expectEqual(TokenType.preprocessor, tokens[0].token_type);
}

test "tokenize C with comment" {
    const lang = detect("test.c").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "int x = 42; // comment", &state, &buf);
    try std.testing.expect(tokens.len >= 2);

    // Last token should be comment
    const last = tokens[tokens.len - 1];
    try std.testing.expectEqual(TokenType.comment, last.token_type);
}

test "tokenize multi-line comment carry-over" {
    const lang = detect("test.c").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    // Start of multi-line comment
    _ = tokenizeLine(lang, "/* this is", &state, &buf);
    try std.testing.expectEqual(State.comment_multi, state);

    // Continuation
    _ = tokenizeLine(lang, "still a comment */", &state, &buf);
    try std.testing.expectEqual(State.normal, state);
}

test "tokenize string with escape" {
    const lang = detect("test.c").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "char *s = \"hello\\nworld\";", &state, &buf);
    var found_string = false;
    for (tokens) |t| {
        if (t.token_type == .string) {
            found_string = true;
            break;
        }
    }
    try std.testing.expect(found_string);
}

test "detect TeX by extension" {
    try std.testing.expectEqualSlices(u8, "TeX", detect("paper.tex").?.name);
    try std.testing.expectEqualSlices(u8, "TeX", detect("style.sty").?.name);
    try std.testing.expectEqualSlices(u8, "TeX", detect("refs.bib").?.name);
    try std.testing.expectEqualSlices(u8, "TeX", detect("class.cls").?.name);
    try std.testing.expectEqualSlices(u8, "TeX", detect("macros.dtx").?.name);
}

test "tokenize TeX command" {
    const lang = detect("paper.tex").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "\\section{Introduction}", &state, &buf);
    // First token should be \section as keyword1
    try std.testing.expect(tokens.len >= 1);
    try std.testing.expectEqual(TokenType.keyword1, tokens[0].token_type);
    try std.testing.expectEqual(@as(usize, 0), tokens[0].start);
    try std.testing.expectEqual(@as(usize, 8), tokens[0].end); // "\section"
}

test "tokenize TeX comment" {
    const lang = detect("paper.tex").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "Hello world % this is a comment", &state, &buf);
    // Last token should be the comment from % onward
    try std.testing.expect(tokens.len >= 1);
    const last = tokens[tokens.len - 1];
    try std.testing.expectEqual(TokenType.comment, last.token_type);
}

test "tokenize TeX bare backslash is not a command" {
    const lang = detect("paper.tex").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    // `\\` (line break) should not be emitted as a command — the second
    // character is not a letter, so the command path doesn't fire.
    const tokens = tokenizeLine(lang, "line\\\\", &state, &buf);
    // Just make sure we didn't emit a keyword1 token by mistake.
    for (tokens) |t| {
        try std.testing.expect(t.token_type != .keyword1);
    }
}

test "tokenize TeX begin environment" {
    const lang = detect("paper.tex").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "\\begin{equation}", &state, &buf);
    // \begin → keyword1, equation → identifier/normal
    try std.testing.expect(tokens.len >= 1);
    try std.testing.expectEqual(TokenType.keyword1, tokens[0].token_type);
}

test "detect new languages and dotfiles" {
    try std.testing.expectEqualSlices(u8, "JavaScript", detect("App.jsx").?.name);
    try std.testing.expectEqualSlices(u8, "Shell", detect("config.zsh").?.name);
    try std.testing.expectEqualSlices(u8, "Shell", detect("/home/u/.bashrc").?.name);
    try std.testing.expectEqualSlices(u8, "Shell", detect(".zshrc").?.name);
    try std.testing.expectEqualSlices(u8, "Makefile", detect("rules.mk").?.name);
    try std.testing.expectEqualSlices(u8, "Dockerfile", detect("Dockerfile").?.name);
    try std.testing.expectEqualSlices(u8, "Dockerfile", detect("sub/dir/Containerfile").?.name);
    try std.testing.expectEqualSlices(u8, "Ruby", detect("app.rb").?.name);
    try std.testing.expectEqualSlices(u8, "Ruby", detect("Gemfile").?.name);
    try std.testing.expectEqualSlices(u8, "Java", detect("Main.java").?.name);
}

test "python triple-quoted string carries across lines" {
    const lang = detect("m.py").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    _ = tokenizeLine(lang, "x = \"\"\"start of doc", &state, &buf);
    try std.testing.expectEqual(State.string_triple_dq, state);

    // Middle line is entirely string.
    const mid = tokenizeLine(lang, "still inside", &state, &buf);
    try std.testing.expectEqual(State.string_triple_dq, state);
    try std.testing.expectEqual(@as(usize, 1), mid.len);
    try std.testing.expectEqual(TokenType.string, mid[0].token_type);

    _ = tokenizeLine(lang, "done\"\"\" + 1", &state, &buf);
    try std.testing.expectEqual(State.normal, state);
}

test "python single-line triple quote closes immediately" {
    const lang = detect("m.py").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;
    _ = tokenizeLine(lang, "s = '''one line'''", &state, &buf);
    try std.testing.expectEqual(State.normal, state);
}

test "js template literal carries across lines" {
    const lang = detect("m.js").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    _ = tokenizeLine(lang, "const s = `line one", &state, &buf);
    try std.testing.expectEqual(State.string_backtick, state);
    _ = tokenizeLine(lang, "line two`;", &state, &buf);
    try std.testing.expectEqual(State.normal, state);
}

test "zig line string covers rest of line" {
    const lang = detect("m.zig").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "    \\\\hello world", &state, &buf);
    try std.testing.expectEqual(State.normal, state);
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqual(TokenType.string, tokens[0].token_type);
    try std.testing.expectEqual(@as(usize, 4), tokens[0].start);
}

test "decimal numbers do not absorb hex letters" {
    const lang = detect("t.c").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "x = 123abc;", &state, &buf);
    // "123" must end before 'a'; "abc" is then a separate identifier.
    var num_end: usize = 0;
    for (tokens) |t| {
        if (t.token_type == .number) num_end = t.end;
    }
    try std.testing.expectEqual(@as(usize, 7), num_end); // "x = 123" → end at 7
}

test "exponent notation tokenizes as one number" {
    const lang = detect("t.c").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "y = 1.5e-3;", &state, &buf);
    var found: ?Token = null;
    for (tokens) |t| {
        if (t.token_type == .number) found = t;
    }
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(usize, 4), found.?.start);
    try std.testing.expectEqual(@as(usize, 10), found.?.end); // "1.5e-3"
}

test "tokenize number formats" {
    const lang = detect("test.c").?;
    var state: State = .normal;
    var buf: [64]Token = undefined;

    const tokens = tokenizeLine(lang, "int x = 0xFF;", &state, &buf);
    var found_number = false;
    for (tokens) |t| {
        if (t.token_type == .number) {
            found_number = true;
            break;
        }
    }
    try std.testing.expect(found_number);
}
