# Configuration Reference

issy reads its configuration from `~/.issyrc` on POSIX systems or `%APPDATA%\issy\config` on Windows. You can override the path with `--config`.

## File Format

Plain text, line-oriented:

```
# This is a comment
key = value
key = "value with spaces"

[theme.paper]
color_key = "#rrggbb"
```

Blank lines and lines starting with `#` are ignored. Unknown keys are silently skipped. Malformed lines are ignored.

## Editor Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `tab_width` | integer | `4` | Number of spaces per tab stop |
| `expand_tabs` | bool | `true` | Insert spaces instead of tab characters |
| `line_numbers` | bool | `true` | Show line numbers in the gutter |
| `word_wrap` | bool | `true` | Soft-wrap long lines at the right margin. Continuation lines are indented 2 spaces. The buffer is not modified. |
| `auto_indent` | bool | `true` | Copy leading whitespace when pressing Enter |
| `auto_close_brackets` | bool | `false` | Automatically insert matching bracket/quote pairs |
| `auto_detect_indent` | bool | `true` | Scan file on open to detect tabs vs spaces and width |
| `trailing_whitespace` | bool | `true` | Faintly highlight trailing spaces/tabs on non-empty lines |
| `indent_mismatch` | bool | `true` | Faintly highlight leading indent that doesn't match the detected file style |
| `scroll_margin` | integer | `5` | Minimum lines between cursor and screen edge before scrolling |

## Visual Design

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `gutter_padding` | integer | `2` | Spaces between line numbers and code |
| `left_padding` | integer | `1` | Spaces before line numbers |
| `right_margin` | integer | `100` | Soft right margin -- code stops here, rest is empty background. `0` fills the terminal width. |
| `cursor_line_bg` | bool | `true` | Subtle full-width highlight on the current line |
| `cursor_style` | string | `bar` | Terminal cursor shape: `bar`, `block`, or `underline` |

## PDF / Print Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `font_file` | string | (none) | Path to a TTF or OTF font file for PDF output. Required for Ctrl+P and `--print`. |
| `font_size` | float | `10.0` | Font size in points for PDF output |
| `print_margin_top` | float | `72.0` | Top margin in points (72 = 1 inch) |
| `print_margin_bottom` | float | `72.0` | Bottom margin in points |
| `print_margin_left` | float | `108.0` | Left margin in points (108 = 1.5 inches) |
| `print_margin_right` | float | `72.0` | Right margin in points |

## Themes

Switch themes by adding a section header:

```
[theme.paper]
```

Built-in themes: `default` (dark), `paper` (light). You can also override individual colors after the section header.

### Theme Color Keys

All colors use `#rrggbb` hex format.

| Key | Description |
|-----|-------------|
| `bg` | Editor background |
| `fg` | Default text color |
| `comment` | Comment color (should be faint) |
| `keyword` | Primary keyword color (control flow) |
| `string_color` | String literal color |
| `number_color` | Number literal color |
| `type_color` | Type name color |
| `function_color` | Function name color |
| `operator_color` | Operator color |
| `preprocessor_color` | Preprocessor directive color |
| `line_number_color` | Line number color (dim) |
| `line_number_active` | Active line number color |
| `cursor_line_color` | Cursor line background tint |
| `selection_color` | Selection background |
| `trailing_ws_color` | Trailing whitespace background tint |
| `indent_mismatch_color` | Indent mismatch background tint |

### Default Theme Colors

```
bg = "#1a1b26"
fg = "#a9b1d6"
keyword = "#bb9af7"
string_color = "#9ece6a"
comment = "#3b4261"
number_color = "#a9b1d6"
type_color = "#7dcfff"
function_color = "#a9b1d6"
operator_color = "#89ddff"
preprocessor_color = "#e0af68"
line_number_color = "#2a2e3f"
line_number_active = "#545c7e"
cursor_line_color = "#1e2030"
selection_color = "#283457"
trailing_ws_color = "#2a1f1f"
indent_mismatch_color = "#2a1f1f"
```

### Paper Theme Colors

```
bg = "#fafafa"
fg = "#4a4a4a"
keyword = "#7c3aed"
string_color = "#16a34a"
comment = "#c4c4c4"
line_number_color = "#e0e0e0"
cursor_line_color = "#f5f5f5"
selection_color = "#e8e0ff"
```

## Boolean Values

Boolean keys accept `true`, `1`, or `yes` for true. Anything else is false.

## Indent Detection

When `auto_detect_indent` is enabled (the default), issy scans the first 100 lines of each file on open. If 60%+ of indented lines use tabs, it switches to tab mode for that file. If 60%+ use spaces, it detects the most common width (2 or 4). These per-file settings override `tab_width` and `expand_tabs` from the config.

## Example

See [examples/issyrc](examples/issyrc) for a fully commented example configuration.
