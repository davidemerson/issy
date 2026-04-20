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
  update.zig      Auto-update: fetch, verify, stage, apply
  update_key.zig  Committed Ed25519 public key (signing trust root)
  build_info.zig  Generated at configure time: version + commit SHA + build type

tools/
  keygen.zig      One-shot Ed25519 keypair generator (zig build keygen)
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

- **Modes**: `normal`, `search`, `command`, `confirm`, `replace`. Each mode has its own key handler. `confirm` carries a `confirm_action` discriminator (`quit`, `new`, or `open`) so the same confirm prompt dispatches to quit, new buffer, or the open-file prompt depending on which key triggered it. Confirm accepts Enter, Ctrl+Q, or Ctrl+W; Escape cancels.
- **Undo/redo**: Each edit pushes an `UndoEntry` with position, deleted bytes (if any), and inserted length. Undo reverses the operation and pushes the inverse to the redo stack. Replace operations (which both delete and insert) produce a single combined entry.
- **Bracket matching**: After each cursor move, scans up to 10,000 characters in each direction for matching `()[]{}` using a nesting-depth counter.
- **Indent detection**: Scans the first 100 lines on file open. If >60% use tabs or spaces, overrides the config's `expand_tabs` and `tab_width` for that file.
- **Multiple cursors**: `Ctrl+D` selects the word under cursor and finds the next occurrence. Editing operations apply to all cursors. Overlapping cursors merge. Escape clears extras.
- **Bracketed paste**: On init the terminal enables DECSET 2004; `ESC[200~` / `ESC[201~` arrive as `paste_start` / `paste_end` keys. The editor toggles an `in_paste` flag across those markers, and while it's set, `insertNewline` skips auto-indent and `insertTab` inserts a literal `\t` so already-formatted pasted content lands verbatim.
- **Missing-file open**: `openFile` treats `error.FileNotFound` as "open as a new empty buffer bound to this filename," so `issy newdoc.md` starts a new file and `Ctrl+S` writes directly. Other errors still surface.
- **Selection-replace on typing**: `insertCodepoint`, `insertNewline`, and `insertTab` each delete the active selection before inserting, matching the backspace/delete behavior.

### term.zig -- Terminal Abstraction

Abstraction over raw terminal I/O (POSIX via termios). issy targets Linux, macOS, and OpenBSD.

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
- **Languages**: 17 definitions with keyword lists, comment syntax, string delimiters, and preprocessor prefixes. Detection is by file extension (or exact filename for Makefile). TeX/LaTeX uses a `command_prefix` field to tokenize `\command` sequences as single keyword tokens instead of relying on keyword lists.
- **Output**: Writes tokens into a caller-provided fixed-size buffer. No heap allocation.

### config.zig -- Configuration

Defines all settings with compile-time defaults. Includes two built-in themes (default dark, paper light) and a separate print theme for PDF output.

- **Parser**: Reads the entire config file into a stack buffer, splits by newlines, parses `key = value` pairs. Supports `[theme.name]` sections and `#rrggbb` hex colors.
- **Print theme**: A separate `PrintTheme` struct with colors tuned for ink on white paper. Used exclusively by `print.zig`.
- **Live reload**: `resolveDefaultPath(buf)` resolves `$HOME/.issyrc` into a caller-provided buffer; `statMtime(path)` returns the file's current mtime. The main loop's existing 1/sec stat tick compares the config path's mtime against the one captured at startup and calls `load()` + `applyCliOverrides()` again when it changes. No file watcher — the poll is free-riding on the same tick that handles external edits to the open buffer.

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

### update.zig -- Auto-update

Detects newer releases, optionally downloads and signature-verifies replacement binaries, and re-execs in place without disturbing the open buffer. Implemented in three phases, all shipping together:

- **Notify** (`startupCheck`, `readCachedState`): On editor startup, reads a cached commit SHA from `~/.cache/issy/commit.txt` and compares against `build_info.commit_sha`. A mismatch sets the in-memory `UpdateState.status` to `.available` and surfaces `update available: <sha>` in the status bar. Dev builds short-circuit the check entirely.
- **Refresh worker** (`spawnWorker`, `doWork`): After reading the cache, the parent double-forks a detached grandchild that refetches `commit.txt` over HTTPS via `std.http.Client`. The grandchild is orphaned (adopted by init) so the editor never has to reap it. `alarm(fetch_timeout_seconds)` caps the worker's total runtime; a stuck TCP connection is killed by SIGALRM rather than lingering forever.
- **Signed download** (`downloadAndStage`, `verifyManifestSignature`, `findAssetHash`): When `cfg.autoupdate` is on and a configured public key is present, the same worker also fetches `sha256sums.txt` and `sha256sums.txt.sig`. The 64-byte raw Ed25519 signature is verified with `std.crypto.sign.Ed25519` against `update_key.public_key`. On success, the worker parses the manifest for our platform's line (`currentAssetName()` picks the right asset from `builtin.target`), downloads the binary, checks its SHA-256 against the signed value, and atomic-renames it into `~/.cache/issy/issy.staged`.
- **Apply** (`apply`, `canAutoApply`, `writeResumeFile`): In the main loop, when all gates are satisfied (a staged binary exists, `autoupdate` is on, buffer is clean, `argv0` is writable, the editor has been idle for 60 seconds), the editor writes a one-shot resume record, snapshots the running binary to `issy.prev`, atomically renames the staged binary over its own executable, tears down the terminal, and `execve()`s the new binary with `--resume <path>`. Termios state lives on the tty device, not the file descriptor, so the terminal survives `execve` cleanly — the user sees one re-render.
- **Resume** (`tryResume`): The new binary, when invoked with `--resume <path>`, reads the resume record, verifies it's fresh (<5 min) and that the file's mtime still matches the snapshot, then restores `cursor.line`/`cursor.col` and shows `upgraded to <sha>` in the footer. Missing or stale records are a safe no-op.
- **Rollback** (`rollback`): `issy --rollback` runs before any TUI init: it renames `issy.prev` back over `argv0` and exits. One-shot, atomic.

All HTTP fetches use bounded `std.Io.Writer.fixed` buffers so a malicious or broken server can't drive memory usage past the per-fetch cap. All failures on the download/verify/stage path are silent and non-fatal — on any error the editor falls back to notify-only and retries on the next run.

### update_key.zig -- Signing Trust Root

Holds the 32-byte Ed25519 public key that the auto-update path verifies `sha256sums.txt.sig` against. Committed to the repo; the matching private key is a GitHub Actions Secret (`UPDATE_SIGNING_KEY`) that only the CI workflow can read. Fresh checkouts start with an all-zero placeholder — `isConfigured()` returns false and the whole signed-download path becomes a no-op until the maintainer runs `zig build keygen` and commits a real key. Forks wanting auto-update for their own releases go through the same bootstrap.

### build_info.zig -- Generated

Written by `build.zig` at configure time via `git rev-parse HEAD` and `git status --porcelain`. On a clean release build (e.g. CI), embeds the full 40-char commit SHA and `build_type = .release`. On a dirty or un-gitted tree, embeds the placeholder `"dev" ++ "0"*37` and `build_type = .dev`, which the update path uses as a kill switch. Always gitignored — never committed.

### tools/keygen.zig -- Keypair Generator

Standalone program, built and run via `zig build keygen`. Generates a fresh Ed25519 keypair using `std.crypto.sign.Ed25519.KeyPair.generate()`, PKCS#8-wraps the private key into a PEM envelope (for pasting into a GitHub Actions Secret), and prints the matching public key as a Zig byte-array literal (for pasting into `update_key.zig`). The private key never touches disk; the caller is responsible for transferring both halves and then deleting the terminal output.

## Build System

`build.zig` defines:

- **`issy` executable**: Links libc on POSIX targets (for termios). Defaults to ReleaseSafe optimization.
- **`cross` step**: Builds for all 5 target platforms.
- **`test` step**: Runs test blocks from every source file independently (not via a root test import -- each file is its own test compilation unit).
- **`keygen` step**: Builds and runs `tools/keygen.zig` to print a fresh signing keypair. Used once per repo to bootstrap the auto-update trust root.
- **`writeBuildInfo` (configure-time)**: Runs `git rev-parse HEAD` + `git status --porcelain` to regenerate `src/build_info.zig` with the current commit SHA and build type. Skipped silently if git is unavailable or the tree is dirty (falls back to `dev`).

## macOS distribution

macOS does not ship prebuilt binaries in GitHub releases. Cross-compiled Mach-O from Linux has no `LC_CODE_SIGNATURE` load command and the Apple Silicon kernel refuses to `execve` it. Rather than grow a cross-signing pipeline, macOS users install via a Homebrew HEAD-install formula (`Formula/issy.rb`) that depends on Zig and builds from source, producing a native host-signed binary that just works on both Intel and Apple Silicon.

The auto-update worker's `currentAssetName()` in `src/update.zig` returns `null` for macOS, which disables the download/verify/stage codepath on that platform. The notify-only path still runs (reads `commit.txt` from the latest release and compares against `build_info.commit_sha`), so macOS users see the "update available" notice in the footer and run `brew upgrade --fetch-HEAD issy` to act on it. CI includes a macOS cross-compile smoke test to catch compilation regressions that would break the brew build.

## Design Constraints

- Zero external dependencies. Zig `std` only.
- Single binary. No runtime config files required.
- No allocations in the render or tokenizer hot paths.
- Terminal state always restored on exit.
