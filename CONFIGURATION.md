# Configuration Reference

issy reads its configuration from `~/.issyrc`. You can override the path with `--config`. The installer seeds a commented default `~/.issyrc` on first install.

**Live reload.** issy re-reads the config file automatically when its modification time changes (checked once per second). Save your changes and you'll see `Config reloaded.` in the status bar; colors, tab width, margins, cursor shape, and other settings take effect on the next frame without restarting. `--theme` and `--font` from the command line are reapplied after every reload so they keep winning over file values.

## File Format

Plain text, line-oriented:

```
# This is a comment
key = value
key = "value with spaces"

[theme.paper]
color_key = "#rrggbb"
```

Blank lines and lines starting with `#` are ignored. Unknown keys are silently skipped. Malformed lines are ignored — and so are out-of-range values (the key keeps its previous value; validation ranges are listed per key below).

## Editor Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `tab_width` | integer | `4` | Number of spaces per tab stop. Valid range 1–8; values outside it are ignored. |
| `expand_tabs` | bool | `true` | Insert spaces instead of tab characters |
| `line_numbers` | bool | `true` | Show line numbers in the gutter |
| `word_wrap` | bool | `true` | Soft-wrap long lines at the right margin. The buffer is not modified. |
| `wrap_indent` | bool | `false` | When soft-wrapping, indent continuation rows to the wrapped line's own leading whitespace (a hanging indent) instead of a flat 2 columns. Capped at half the wrap width. |
| `auto_indent` | bool | `true` | Copy leading whitespace when pressing Enter |
| `auto_close_brackets` | bool | `false` | Automatically insert the matching `)`, `]`, `}`, `"`, `'`, or `` ` `` when you type an opener, leaving the cursor between the pair. Typing the closer when it already sits at the cursor steps over it; backspacing an empty pair deletes both; and typing an opener with text selected wraps the selection. Quote pairing is suppressed next to word characters (so apostrophes in prose stay literal). |
| `swap_files` | bool | `true` | While a buffer has unsaved changes, periodically write them to a sibling `.<name>.swp` file; it is removed on save or clean exit. On open, a leftover swap (from a crash) is reported in the status bar. Best-effort — silent when the directory isn't writable. |
| `auto_detect_indent` | bool | `true` | Scan file on open to detect tabs vs spaces and width |
| `trailing_whitespace` | bool | `true` | Faintly highlight trailing spaces/tabs on non-empty lines |
| `indent_mismatch` | bool | `true` | Faintly highlight leading indent that doesn't match the detected file style |
| `scroll_margin` | integer | `5` | Minimum lines between cursor and screen edge before scrolling. Valid range 0–100. |

## Visual Design

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `gutter_padding` | integer | `3` | Spaces between line numbers and code. Valid range 0–32. |
| `left_padding` | integer | `2` | Spaces before line numbers. Valid range 0–32. |
| `right_margin` | integer | `100` | Soft right margin -- code stops here, rest is empty background. `0` fills the terminal width. Capped at 2000. |
| `cursor_line_bg` | bool | `true` | Subtle full-width highlight on the current line |
| `cursor_style` | string | `bar` | Terminal cursor shape: `bar`, `block`, or `underline` |

## Auto-update

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `notify_updates` | bool | `true` | On startup, check whether a newer release exists and show `update available: <sha>` in the status bar. Set to `false` to disable the check (and the background network fetch that refreshes its cache) entirely. |
| `autoupdate` | bool | `false` | Opt into automatic download, signature verification, and in-session apply. When on, the editor downloads the signed `sha256sums.txt` manifest from the latest release, verifies it against the Ed25519 public key committed to `src/update_key.zig`, checks the manifest's embedded commit + monotonic epoch against the cached high-water mark (rejecting replayed older releases), downloads the matching platform binary, hashes it, stages it at `~/.cache/issy/issy.staged`, and — when the buffer is clean and the editor has been idle for 60 seconds — re-verifies the staged binary against the cached signed manifest, atomic-renames it into place, and re-execs. |

Both keys are no-ops for `dev` builds (any working tree that wasn't built from a clean CI checkout). When the editor binary itself is not writable by the running user — the common case for distro-packaged installs at `/usr/bin/issy` — the background worker still fetches, verifies, and stages the update in the cache, but the in-session apply is silently skipped, so the editor effectively stays in notify-only mode.

**macOS specifically**: `autoupdate = true` is silently a no-op because issy does not ship prebuilt macOS binaries (cross-compiled Mach-O from Linux has no code signature and is refused by the Apple Silicon kernel). `notify_updates` still works — macOS users see the "update available" notice and run `brew upgrade issy` (or `brew upgrade --fetch-HEAD issy` if they installed with `--HEAD`) to actually update.

The complete cache layout (all under `~/.cache/issy/`):

- `commit.txt` — latest-release commit SHA
- `sha256sums.txt` / `sha256sums.txt.sig` — verified signed manifest + signature; used to re-verify `issy.staged` at apply time
- `manifest_epoch.txt` — highest manifest epoch ever accepted (anti-rollback high-water mark)
- `issy.staged` — verified replacement binary, waiting to be applied
- `issy.prev` / `issy.prev.sha256` — pre-apply snapshot for `issy --rollback`, plus its checksum (rollback refuses a snapshot that no longer matches)
- `resume.<ts>.txt` — one-shot cursor snapshot used by the new instance to restore position after re-exec

See the [Auto-update section of README.md](README.md#auto-update) for the full flow, including the bootstrap procedure for forks that want to sign their own releases.

## PDF / Print Settings

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `font_file` | string | (none) | Path to a TTF or OTF font file for PDF output. Required for Ctrl+P and `--print`. |
| `font_size` | float | `10.0` | Font size in points for PDF output. Valid range 4–144. |
| `print_margin_top` | float | `72.0` | Top margin in points (72 = 1 inch). Must be ≥ 0. |
| `print_margin_bottom` | float | `72.0` | Bottom margin in points. Must be ≥ 0. |
| `print_margin_left` | float | `108.0` | Left margin in points (108 = 1.5 inches). Must be ≥ 0. |
| `print_margin_right` | float | `72.0` | Right margin in points. Must be ≥ 0. |

Margins that leave no usable content area (top + bottom taller than the page, or left + right wider than it) make PDF export fail with a `MarginsTooLarge` error rather than emitting a broken document. Page headers are drawn only when the top margin leaves room for one (roughly ≥ 2 line heights).

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

Black background with restrained syntax colors.

```
bg = "#000000"
fg = "#b0b8c8"
keyword = "#c4a0f7"
string_color = "#a0d06e"
comment = "#444c5e"
number_color = "#b0b8c8"
type_color = "#7dcfff"
function_color = "#b0b8c8"
operator_color = "#89ddff"
preprocessor_color = "#e0af68"
line_number_color = "#282c36"
line_number_active = "#505868"
cursor_line_color = "#0d0d14"
selection_color = "#1a2844"
trailing_ws_color = "#1a1010"
indent_mismatch_color = "#1a1010"
```

### Paper Theme Colors (Solarized Light)

```
bg = "#fdf6e3"
fg = "#657b83"
keyword = "#6c71c4"
string_color = "#2aa198"
comment = "#93a1a1"
number_color = "#d33682"
type_color = "#b58900"
function_color = "#268bd2"
operator_color = "#657b83"
preprocessor_color = "#cb4b16"
line_number_color = "#eee8d5"
line_number_active = "#93a1a1"
cursor_line_color = "#eee8d5"
selection_color = "#eee8d5"
```

## Boolean Values

Boolean keys accept `true`, `1`, or `yes` for true. Anything else is false.

## Indent Detection

When `auto_detect_indent` is enabled (the default), issy scans the first 100 lines of each file on open. If 60%+ of indented lines use tabs, it switches to tab mode for that file. If 60%+ use spaces, it detects the most common width (2 or 4). These per-file settings override `tab_width` and `expand_tabs` from the config.

## Example

See [examples/issyrc](examples/issyrc) for a fully commented example configuration.

## Cache Files

issy keeps a small cache directory at `~/.cache/issy/`:

| File | Purpose |
|------|---------|
| `commit.txt`, `sha256sums.txt`, `sha256sums.txt.sig`, `manifest_epoch.txt`, `issy.staged`, `issy.prev`, `issy.prev.sha256` | Auto-update state — see [README](README.md#auto-update). |
| `positions.txt` | Per-file cursor memory. One `<abs_path>\t<line>\t<col>` entry per line, newest on top, capped at 300 entries. Corruption or a missing file is treated as "no saved positions" — the feature is best-effort. Delete it any time to reset. |

Nothing in `~/.cache/issy/` is required for correct operation; it can be wiped without data loss.
