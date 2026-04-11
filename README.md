# issy

A text editor that looks like a printed page, not a terminal application.

Built in Zig with zero external dependencies. Single binary, cross-compiles to Linux, macOS, Windows, and OpenBSD. Gap buffer text storage, syntax highlighting for 16 languages, PDF export with TTF/OTF font embedding, multiple cursors, undo/redo, and incremental search.

## Build

Requires [Zig](https://ziglang.org/) 0.15+.

```sh
zig build                              # debug build
zig build -Doptimize=ReleaseSafe       # release build (~470KB)
zig build test                         # run all tests
```

The binary is placed in `zig-out/bin/issy`.

### Cross-compile

```sh
zig build -Dtarget=x86_64-linux-gnu
zig build -Dtarget=x86_64-macos
zig build -Dtarget=aarch64-macos
zig build -Dtarget=x86_64-windows-gnu
zig build -Dtarget=x86_64-openbsd
```

Or build all cross targets at once:

```sh
zig build cross
```

## Usage

```
issy [options] [file[:line]]
```

Open a file:

```sh
issy main.zig
issy src/editor.zig:42    # open at line 42
issy                      # empty buffer
```

### Options

| Flag | Description |
|------|-------------|
| `--version`, `-v` | Print version and exit |
| `--help`, `-h` | Print usage and exit |
| `--config FILE` | Use a specific config file |
| `--theme NAME` | Override theme (`default`, `paper`) |
| `--font PATH` | TTF/OTF font for PDF output |
| `--no-config` | Skip loading config file |
| `--print FILE` | Export to PDF and exit (no TUI) |

### Headless PDF export

```sh
issy --font /path/to/font.ttf --print output.pdf source.c
```

## Keybindings

### Editing

| Key | Action |
|-----|--------|
| Ctrl+S | Save |
| Ctrl+Q | Quit (press twice to discard unsaved changes) |
| Ctrl+Z | Undo |
| Ctrl+Y | Redo |
| Ctrl+C | Copy selection |
| Ctrl+X | Cut selection |
| Ctrl+V | Paste |
| Ctrl+A | Select all |
| Tab | Insert tab or spaces (per config) |
| Enter | Newline with auto-indent |

### Navigation

| Key | Action |
|-----|--------|
| Arrow keys | Move cursor |
| Home / End | Start / end of line |
| Page Up / Down | Scroll by page |
| Mouse scroll | Scroll viewport (cursor stays) |
| Mouse click | Position cursor |

### Search and Replace

| Key | Action |
|-----|--------|
| Ctrl+F | Incremental search (Escape cancels, Enter confirms) |
| Ctrl+G | Find next match |
| Ctrl+H | Search and replace (Tab switches fields, Enter replaces next, Ctrl+A replaces all) |

### Files and Buffers

| Key | Action |
|-----|--------|
| Ctrl+O | Open file (prompts for path) |
| Ctrl+N | New empty buffer |
| Ctrl+P | Export to PDF (requires `font_file` in config) |
| Ctrl+R | Reload file from disk |
| Ctrl+W | Same as Ctrl+Q |

### Multiple Cursors

| Key | Action |
|-----|--------|
| Ctrl+D | Select word under cursor; press again to add cursor at next occurrence |
| Escape | Clear all extra cursors and selection |

All editing operations (typing, backspace, delete, paste) apply to every cursor simultaneously.

## Configuration

Create `~/.issyrc` (POSIX) or `%APPDATA%\issy\config` (Windows). See [CONFIGURATION.md](CONFIGURATION.md) for the full reference, or copy [examples/issyrc](examples/issyrc) as a starting point.

Quick example:

```
tab_width = 4
expand_tabs = true
line_numbers = true
right_margin = 100
cursor_style = bar
font_file = "/path/to/font.ttf"

[theme.paper]
```

## Themes

**default** -- Dark, restrained. Background `#1a1b26`, text `#a9b1d6`. Keywords are violet, strings are soft green, comments are nearly invisible. Most syntax colors sit close to the foreground luminance. The cursor line is a barely perceptible band.

**paper** -- Light, same philosophy. Background `#fafafa`, text `#4a4a4a`. Purple keywords, green strings, light gray comments.

Both themes follow the design principle: only 2-3 token types get real chromatic contrast. The eye parses structure through gentle luminance shifts, not a rainbow.

See [DESIGN.md](DESIGN.md) for the full visual design philosophy.

## Syntax Highlighting

C, C++, Zig, Python, JavaScript, TypeScript, Rust, Go, Shell, HTML, CSS, JSON, YAML, TOML, Makefile, Markdown.

Language is detected by file extension.

## PDF Printing

Requires a TTF or OTF font file set via `font_file` in your config or `--font` on the command line. PDF output uses a separate print theme with colors tuned for ink on white paper -- it never inherits the dark TUI theme.

```sh
# From within the editor: Ctrl+P
# From the command line:
issy --font "Berkeley Mono.ttf" --print output.pdf source.py
```

Recommended fonts: Berkeley Mono, Iosevka, JetBrains Mono, Commit Mono.

## Architecture

See [ARCHITECTURE.md](ARCHITECTURE.md) for a tour of the source code.

## Man Page

```sh
man ./issy.1
```

## License

ISC
