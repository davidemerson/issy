# Architecture

issy is structured as a set of Zig modules with clear responsibilities and minimal coupling. Everything lives in `src/` with a single `build.zig` at the root.

## Module Map

```
src/
  main.zig        Entry point, arg parsing, main loop
  editor.zig      Central editor state and key handling
  buffer.zig      Gap buffer text storage
  render.zig      Cell grid diffing and terminal output
  term.zig        Raw terminal I/O abstraction
  syntax.zig      Tokenizer and language definitions
  config.zig      Configuration, themes, color constants
  unicode.zig     UTF-8 encode/decode utilities
  font.zig        TTF/OTF parser for PDF embedding
  print.zig       PDF 1.4 generation
```

## Data Flow

```
stdin --> term.zig --> main.zig --> editor.zig --> buffer.zig
                                       |
                                       v
                        render.zig --> term.zig --> stdout
```

1. `term.zig` reads raw bytes from stdin into a read-ahead buffer and parses them into `Key` values (characters, escape sequences, mouse events).
2. `main.zig` runs the event loop: render frame, read key, dispatch to editor, check for quit.
3. `editor.zig` translates keys into buffer operations (insert, delete, cursor movement) and state changes (mode transitions, undo stack).
4. `render.zig` reads the editor state, fills a cell grid, diffs against the previous frame, and emits only the changed terminal escape sequences through `term.zig`.

## Module Details

### buffer.zig -- Gap Buffer

The core text data structure. A contiguous byte array with a "gap" (unused region) that moves to the cursor position for O(1) local inserts and deletes.

- **Capacity growth**: Doubles when the gap shrinks below 64 bytes.
- **Line indexing**: `getLine(n)` scans for newlines and returns byte offset + length (excluding the newline). Line count is cached and invalidated on edit.
- **Zero-copy reads**: `contiguousSlice()` returns a direct pointer into the backing array when the requested range doesn't cross the gap, falling back to a caller-provided temp buffer when it does.
- **Atomic save**: Writes to a `.tmp` file then renames, so a crash during save can't corrupt the original.

### editor.zig -- Editor State

The central struct. Owns the buffer, cursor(s), mode, undo/redo stacks, clipboard, and all editing logic.

- **Modes**: `normal`, `search`, `command`, `confirm`, `replace`. Each mode has its own key handler.
- **Undo/redo**: Each edit pushes an `UndoEntry` with position, deleted bytes (if any), and inserted length. Undo reverses the operation and pushes the inverse to the redo stack. Replace operations (which both delete and insert) produce a single combined entry.
- **Bracket matching**: After each cursor move, scans up to 10,000 characters in each direction for matching `()[]{}` using a nesting-depth counter.
- **Indent detection**: Scans the first 100 lines on file open. If >60% use tabs or spaces, overrides the config's `expand_tabs` and `tab_width` for that file.
- **Multiple cursors**: `Ctrl+D` selects the word under cursor and finds the next occurrence. Editing operations apply to all cursors. Overlapping cursors merge. Escape clears extras.

### term.zig -- Terminal Abstraction

Platform abstraction over raw terminal I/O (currently POSIX via termios, Windows support is stubbed).

- **Raw mode**: Disables echo, canonical mode, and signal processing. Sets 100ms read timeout.
- **Read-ahead buffer**: A 256-byte buffer sits between `read()` and key parsing. When multiple keystrokes arrive in one `read()` call, they're consumed one at a time across successive `readKey()` calls. This prevents input loss during fast typing.
- **Write buffer**: 16KB buffer batches output, flushed in a single `write()` syscall.
- **Mouse**: Enables SGR extended mouse reporting for button clicks and scroll wheel. Other mouse events (drag, right-click) are filtered out.
- **Color**: Supports truecolor (`COLORTERM=truecolor`), falling back to xterm-256 color via `rgbTo256()`.
- **Alternate screen**: Enters on init, leaves on deinit. Terminal state is always restored, even on panic.

### render.zig -- Screen Renderer

Double-buffered cell grid. Each frame:

1. Fills the entire grid with background-colored spaces.
2. Computes layout geometry (left padding, gutter, code area, right margin).
3. Renders line numbers, code with syntax colors, cursor line highlight, bracket match, trailing whitespace tint, and multi-cursor reverse-video.
4. Renders the status bar (filename left, line:col right, no chrome).
5. Renders mode-specific prompts on the last row (search, replace, command, confirm).
6. Diffs current vs previous frame cell-by-cell, emitting only changed cells with minimal escape sequences.

### syntax.zig -- Syntax Highlighting

A state machine tokenizer with no allocations in the hot path.

- **State**: Carries `normal`, `comment_multi`, or `string` across lines.
- **Token types**: `keyword1`, `keyword2`, `comment`, `string`, `number`, `typ`, `function`, `operator`, `preprocessor`, `normal`.
- **Languages**: 16 definitions with keyword lists, comment syntax, string delimiters, and preprocessor prefixes. Detection is by file extension (or exact filename for Makefile).
- **Output**: Writes tokens into a caller-provided fixed-size buffer. No heap allocation.

### config.zig -- Configuration

Defines all settings with compile-time defaults. Includes two built-in themes (default dark, paper light) and a separate print theme for PDF output.

- **Parser**: Reads the entire config file into a stack buffer, splits by newlines, parses `key = value` pairs. Supports `[theme.name]` sections and `#rrggbb` hex colors.
- **Print theme**: A separate `PrintTheme` struct with colors tuned for ink on white paper. Used exclusively by `print.zig`.

### font.zig -- TTF/OTF Parser

Parses TrueType and OpenType font files for PDF embedding.

- **Tables parsed**: `head` (units, bbox), `hhea`/`hmtx` (advance widths), `maxp` (glyph count), `OS/2` (ascender, descender, cap height), `name` (family/style), `cmap` format 4 (BMP character mapping), `post` (fixed pitch flag).
- **Glyph metrics**: `charWidth()` and `stringWidth()` measure text at a given point size.
- **Raw data**: The entire font file is kept in memory for embedding as-is into the PDF stream.

### print.zig -- PDF Generation

Hand-rolled PDF 1.4 writer.

- **Font embedding**: Full TTF/OTF file embedded as a stream object, referenced by a CIDFont Type2 (TTF) or Type0 (OTF) font dictionary with a ToUnicode CMap.
- **Content rendering**: Text is encoded as hex glyph IDs (`<XXXX> Tj`), with proper UTF-8 decoding. Colors come from the print theme, not the TUI theme.
- **Page layout**: US Letter (612x792 pts), configurable margins, automatic page breaks.
- **Structure**: Objects written sequentially, byte offsets tracked for the xref table. The Pages object is rewritten at the end once page count is known.

### unicode.zig -- UTF-8 Utilities

Low-level functions: `decode`, `encode`, `utf8Len`, `countCodepoints`, `validate`, `isContByte`. Returns U+FFFD for malformed input. No allocations.

## Build System

`build.zig` defines:

- **`issy` executable**: Links libc on POSIX targets (for termios). Defaults to ReleaseSafe optimization.
- **`cross` step**: Builds for all 5 target platforms.
- **`test` step**: Runs test blocks from every source file independently (not via a root test import -- each file is its own test compilation unit).

## Design Constraints

- Zero external dependencies. Zig `std` only.
- Single binary. No runtime config files required.
- No allocations in the render or tokenizer hot paths.
- Terminal state always restored on exit.
