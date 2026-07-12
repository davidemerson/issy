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
  positions.zig   Per-file cursor memory (~/.cache/issy/positions.txt)
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
2. `main.zig` runs the event loop: render frame (only when something changed — quiet 100ms ticks skip the repaint entirely, so an idle editor costs near-zero CPU), read key, dispatch to editor, check for quit. It also installs a panic handler and SIGTERM/SIGHUP handlers so the terminal is restored on every exit path, not just a clean quit.
3. `editor.zig` translates keys into buffer operations (insert, delete, cursor movement) and state changes (mode transitions, undo stack).
4. `render.zig` reads the editor state, fills a cell grid, diffs against the previous frame, and emits only the changed terminal escape sequences through `term.zig`.

## Module Details

### buffer.zig -- Gap Buffer

The core text data structure. A contiguous byte array with a "gap" (unused region) that moves to the cursor position for O(1) local inserts and deletes.

- **Capacity growth**: Doubles when the gap shrinks below 64 bytes.
- **Line index**: an array of line-start byte offsets, rebuilt lazily with a single memchr-style scan over the two gap segments after any edit. `getLine(n)` and `lineCount()` are O(1); `lineOfPos()` is a binary search. This keeps rendering O(visible rows) instead of O(rows × file size).
- **Search**: `find(pattern, from, ignore_case)` runs `std.mem.indexOf` (or the ASCII case-insensitive variant) over each gap segment directly, plus a small stitched window across the gap boundary — no per-byte function calls.
- **Zero-copy reads**: `contiguousSlice()` returns a direct pointer into the backing array when the requested range doesn't cross the gap, falling back to a caller-provided temp buffer when it does (asserted large enough in Debug builds).
- **Line endings**: files whose lines are uniformly CRLF are normalized to LF on load and written back with CRLF on save; mixed-ending files pass through untouched.
- **Atomic save**: resolves symlinks with readlink(2) so saving through a link rewrites the target (not the link), preserves the original permission bits with fchmod, writes to a `.tmp` sibling, fsyncs, then renames — a crash during save can't corrupt or truncate the original. `load()` allocates the replacement backing array before freeing the old one, so allocation failure leaves the buffer intact.
- **Dirty watermark**: the smallest byte position edited since the renderer last asked, consumed by the renderer's syntax-state cache invalidation.

### editor.zig -- Editor State

The central struct. Owns the buffer, cursor(s), mode, undo/redo stacks, clipboard, and all editing logic.

- **Modes**: `normal`, `search`, `command`, `confirm`, `replace`, `help`. Each mode has its own key handler. `confirm` carries a `confirm_action` discriminator (`quit`, `new`, `open`, or `reload`) so the same confirm prompt dispatches to quit, new buffer, the open-file prompt, or a reload depending on which key triggered it. Confirm accepts Enter, Ctrl+Q, or Ctrl+W; Escape cancels.
- **Undo/redo**: Each edit pushes an `UndoEntry` with position, deleted bytes (if any), and inserted length. Undo reverses the operation and pushes the inverse to the redo stack. Replace operations (which both delete and insert) produce a single combined entry, and Replace All shares one group id so the whole pass is a single undo step. Consecutive word-character inserts within a 500 ms window at adjacent positions are folded into the previous entry via `tryCoalesceInsert` — typing "hello" is one undo step, not five. Whitespace chars, Enter, Tab, cursor movement, backspace, paste, and multi-cursor edits all end the coalesced run. The stack is capped at 10,000 entries (the oldest tenth is dropped at the cap, never splitting a group), and — critically — both stacks are cleared whenever the buffer contents are wholesale replaced (open, new, reload): stale entries hold byte offsets into the old content and replaying them would corrupt the new buffer.
- **Search**: smart-case (all-lowercase patterns match ASCII case-insensitively) plus an optional whole-word toggle (Tab in the prompt), both funnelled through `Editor.findMatch` so the editor and the renderer's viewport highlighting agree. Incremental search re-anchors at the position where search mode was entered on every keystroke; Up/Down (or Ctrl+G, in normal or search mode) walk between matches; match count / current index are recomputed per jump for the `current/total` counter, and the match at the cursor is underlined.
- **Auto-close brackets** (opt-in): typing an opener inserts the matching closer with the cursor between them (one undo step); typing a closer that already sits at the cursor steps over it; backspacing an empty pair deletes both; typing an opener over a selection wraps it. Quote pairing is suppressed adjacent to word characters.
- **Reload**: Ctrl+R always reloads from disk (with a confirm prompt if the buffer is dirty). An external mtime change is surfaced in the status bar within a second, even while idle.
- **Swap-file autosave** (on by default): while the buffer is dirty, the main loop's 1/sec tick writes it to a sibling `.<name>.swp` (throttled to every 2s), removed on save, reload, new buffer, file switch, and clean quit. On open, a leftover swap is reported (not auto-loaded).
- **Scroll math**: `ensureCursorVisible` positions the viewport in O(visible rows), walking visual rows upward from the cursor, so a far goto-line into a wrapped file is instant rather than O(distance²). `scroll_left` is stored as a visual column. Soft-wrap continuation indent comes from `continuationIndentCols` (flat 2, or a hanging indent under the line's own whitespace when `wrap_indent` is on), shared by the editor, renderer, and PDF writer.
- **Bracket matching**: After each cursor move, scans up to 10,000 characters in each direction for matching `()[]{}` using a nesting-depth counter.
- **Indent detection**: Scans the first 100 lines on file open. If >60% use tabs or spaces, overrides the config's `expand_tabs` and `tab_width` for that file.
- **Multiple cursors**: `Ctrl+D` selects the word under cursor and finds the next occurrence. Editing operations apply to all cursors. Overlapping cursors merge. Escape clears extras.
- **Bracketed paste**: On init the terminal enables DECSET 2004; `ESC[200~` / `ESC[201~` arrive as `paste_start` / `paste_end` keys. The editor toggles an `in_paste` flag across those markers, and while it's set, `insertNewline` skips auto-indent and `insertTab` inserts a literal `\t` so already-formatted pasted content lands verbatim.
- **System clipboard (OSC 52)**: `copySelection` pushes the copied bytes out to the terminal's system clipboard via `term.writeOsc52Clipboard`, which base64-encodes in 768-byte chunks (a multiple of 3, so no padding appears mid-stream) and wraps the result in `ESC]52;c;<b64>\a`. Capped at 100 KB of raw data; longer selections only go to the internal clipboard. Paste direction (OS → issy) is served by bracketed paste, so `Ctrl+V` still reads from the internal clipboard.
- **Missing-file open**: `openFile` treats `error.FileNotFound` as "open as a new empty buffer bound to this filename," so `issy newdoc.md` starts a new file and `Ctrl+S` writes directly. Other errors still surface.
- **Selection-replace on typing**: `insertCodepoint`, `insertNewline`, and `insertTab` each delete the active selection before inserting, matching the backspace/delete behavior.

### term.zig -- Terminal Abstraction

Abstraction over raw terminal I/O (POSIX via termios). issy targets Linux, macOS, and OpenBSD.

- **Raw mode**: Disables echo, canonical mode, and signal processing. Sets 100ms read timeout.
- **Read-ahead buffer**: A 256-byte buffer sits between `read()` and key parsing. When multiple keystrokes arrive in one `read()` call, they're consumed one at a time across successive `readKey()` calls, and the buffer compacts so an in-flight escape sequence at its tail can complete.
- **Escape parsing**: a single parser returns "key + consumed length" or *incomplete*. An incomplete CSI (e.g. `ESC [` split across reads over SSH) triggers a bounded re-read instead of being misread as a bare Escape plus stray text; a bare ESC before an unrelated byte consumes only the ESC. Runaway parameter strings are flushed as `.unknown` after 32 bytes.
- **Mouse**: SGR extended mouse reporting for clicks, drag (mode 1002), and scroll. Modifier bits on wheel events (shift/ctrl/meta-scroll) are stripped so a modified scroll still scrolls. UTF-8 input is decoded by the shared, validating `unicode.decode`.
- **Write buffer**: 16KB buffer batches output, flushed with as few `write()` calls as the kernel allows (one, barring short writes).
- **Color**: Supports truecolor (`COLORTERM=truecolor`), falling back to xterm-256 color via `rgbTo256()`.
- **Alternate screen**: Enters on init, leaves on deinit. `emergencyRestore()` is a crash-path variant used by the panic handler — it bypasses the buffered writer and restores termios directly.

### render.zig -- Screen Renderer

Double-buffered cell grid. Each frame:

1. Fills the entire grid with background-colored spaces.
2. Computes layout geometry (left padding, gutter, code area, right margin).
3. Renders line numbers, code with syntax colors, cursor line highlight, bracket match, trailing whitespace tint, live search-match highlighting (search/replace mode), and multi-cursor reverse-video.
4. Renders the status bar (filename left, line:col right, no chrome). All human text — filename, status message, prompts — is written one codepoint per cell via a UTF-8 helper, so non-ASCII names don't garble.
5. Renders mode-specific prompts on the last row (search with its `current/total` match counter, replace, command, confirm).
6. Diffs current vs previous frame cell-by-cell (char, colors, and attributes), emitting only changed cells with minimal escape sequences.

The renderer owns a **syntax-state cache**: the tokenizer state at the start of every line, extended incrementally as the user scrolls and invalidated from the edit point via the buffer's dirty watermark. This is what keeps a `/* ... */` block highlighted as a comment when its opening delimiter is scrolled above the viewport, without re-tokenizing the file per frame.

### syntax.zig -- Syntax Highlighting

A state machine tokenizer with no allocations in the hot path.

- **State**: Carries `normal`, `comment_multi`, and multi-line string states (`string_triple_dq`/`string_triple_sq` for Python triple quotes, `string_backtick` for JS/TS template literals) across lines.
- **Token types**: `keyword1`, `keyword2`, `comment`, `string`, `number`, `typ`, `function`, `operator`, `preprocessor`, `normal`.
- **Languages**: 20 definitions (C, C++, Zig, Python, JavaScript, TypeScript, Rust, Go, Ruby, Java, Shell, HTML, CSS, JSON, YAML, TOML, Makefile, Dockerfile, Markdown, TeX) with keyword lists, comment syntax, string delimiters, and preprocessor prefixes. Detection is by file extension or exact filename (Makefile, Dockerfile, Gemfile, Rakefile; shell dotfiles like `.bashrc` match through the extension path). TeX/LaTeX uses a `command_prefix` field to tokenize `\command` sequences as single keyword tokens; Zig's `\\` line strings use `line_string_prefix`.
- **Numbers**: radix prefixes (`0x`/`0b`/`0o`) constrain the digit set, decimal literals accept `e`/`E` exponents with optional sign, and plain decimals no longer absorb stray hex letters.
- **Output**: Writes tokens into a caller-provided fixed-size buffer. No heap allocation.

### config.zig -- Configuration

Defines all settings with compile-time defaults. Includes two built-in themes (default dark, paper light) and a separate print theme for PDF output.

- **Parser**: Reads the entire config file into a stack buffer, splits by newlines, parses `key = value` pairs. Supports `[theme.name]` sections and `#rrggbb` hex colors. Numeric values are validated (e.g. `tab_width` 1–8, `font_size` 4–144, non-negative print margins); out-of-range values are ignored like malformed lines, never clamped, so a typo can't put the editor in a state the code doesn't expect.
- **Print theme**: A separate `PrintTheme` struct with colors tuned for ink on white paper. Used exclusively by `print.zig`.
- **Live reload**: `resolveDefaultPath(buf)` resolves `$HOME/.issyrc` into a caller-provided buffer; `statMtime(path)` returns the file's current mtime. The main loop's existing 1/sec stat tick compares the config path's mtime against the one captured at startup and calls `load()` + `applyCliOverrides()` again when it changes. No file watcher — the poll is free-riding on the same tick that handles external edits to the open buffer.

### positions.zig -- Per-File Cursor Memory

Stores the most-recent cursor (line, col) per file path to `~/.cache/issy/positions.txt`, so reopening a file drops the caret back where you left it. Best-effort — any I/O error silently disables persistence for that call. Keys are absolute paths built by cwd-prefixing relative ones (symlinks deliberately stay unresolved; `Dir.realpath` is unsupported on OpenBSD), so the same file opened via different relative paths from the same directory matches.

- **File format**: one entry per line, `<abs_path>\t<line>\t<col>\n`. Newest on top. Capped at 300 entries — the oldest get dropped on the next write. Parsing splits from the right on tabs so paths that themselves contain tabs still decode correctly.
- **Atomic write**: same `.tmp` + rename pattern `buffer.zig` uses for source saves.
- **Integration**: `Editor.persistCursor` is called from (a) the main loop's quit branch, (b) `save` / save-as, and (c) the top of `openFile` before the outgoing buffer is replaced. `openFile` then calls `restoreCursorFromPositions` to consult the store, clamped to the loaded file's actual dimensions.
- **Override**: an explicit `file:line` on the command line always wins over the remembered position.

### font.zig -- TTF/OTF Parser

Parses TrueType and OpenType font files for PDF embedding.

- **Tables parsed**: `head` (units, bbox), `hhea`/`hmtx` (advance widths), `maxp` (glyph count), `OS/2` (ascender, descender, cap height), `name` (family/style), `cmap` formats 12 and 4 — subtables are scored and the best Unicode one wins, so modern format-12-only fonts map correctly (BMP portion) — and `post` (fixed pitch flag).
- **Glyph metrics**: `charWidth()` and `stringWidth()` measure text at a given point size.
- **Raw data**: The entire font file is kept in memory for embedding as-is into the PDF stream.

### print.zig -- PDF Generation

Hand-rolled PDF 1.4 writer.

- **Font embedding**: Full TTF/OTF file embedded as a stream object, referenced by a CIDFontType2 (TTF) or CIDFontType0 (OTF) dictionary carrying a real `/W` per-glyph widths array (run-length compressed), and a ToUnicode CMap built from the font's actual glyph→Unicode reverse mapping so copy-paste out of the PDF yields real text.
- **Content rendering**: Text is encoded as hex glyph IDs (`<XXXX> Tj`), split into color runs — each token gets its print-theme color, with tokenizer state carried across the whole document (a line resuming on the next page is not re-tokenized). Tabs expand relative to their running visual column so alignment survives the run splitting.
- **Page layout**: US Letter (612x792 pts), configurable margins (validated: margins that leave no content area are an error, not an infinite loop), automatic page breaks, and a filename + page-number header when the top margin has room.
- **Structure**: Objects written sequentially, byte offsets tracked for the xref table. The Pages object is rewritten at the end once page count is known. All write paths propagate allocation errors — an OOM aborts the export instead of silently emitting a corrupt file.

### unicode.zig -- UTF-8 Utilities

Low-level functions: `decode`, `encode`, `utf8Len`, `countCodepoints`, `validate`, `isContByte`. Returns U+FFFD for malformed input. No allocations.

### update.zig -- Auto-update

Detects newer releases, optionally downloads and signature-verifies replacement binaries, and re-execs in place without disturbing the open buffer. Implemented in three phases, all shipping together:

- **Notify** (`startupCheck`, `readCachedState`): On editor startup, reads a cached commit SHA from `~/.cache/issy/commit.txt` and compares against `build_info.commit_sha`. A mismatch sets the in-memory `UpdateState.status` to `.available` and surfaces `update available: <sha>` in the status bar. Dev builds short-circuit the check entirely.
- **Refresh worker** (`spawnWorker`, `doWork`): After reading the cache, the parent double-forks a detached grandchild that refetches `commit.txt` over HTTPS via `std.http.Client`. The grandchild is orphaned (adopted by init) so the editor never has to reap it. `alarm(fetch_timeout_seconds)` caps the worker's total runtime; a stuck TCP connection is killed by SIGALRM rather than lingering forever.
- **Signed download** (`downloadAndStage`, `verifyManifestSignature`, `findAssetHash`): When `cfg.autoupdate` is on and a configured public key is present, the same worker also fetches `sha256sums.txt` and `sha256sums.txt.sig`. The 64-byte raw Ed25519 signature is verified with `std.crypto.sign.Ed25519` against `update_key.public_key`. Two header lines live *inside* the signed manifest: `# issy-commit: <sha>` binds it to its release (must match the fetched `commit.txt`), and `# issy-manifest-epoch: <ts>` is a monotonic counter checked against the cached high-water mark in `manifest_epoch.txt` — an authentic-but-older manifest (a replay/downgrade) is rejected. On success, the worker parses the manifest for our platform's line (`currentAssetName()` picks the right asset from `builtin.target`), downloads the binary, checks its SHA-256 against the signed value, persists the verified manifest + signature to the cache, records the epoch, and atomic-renames the binary into `~/.cache/issy/issy.staged`.
- **Apply** (`apply`, `canAutoApply`, `verifyStagedBinary`, `writeResumeFile`): In the main loop, when all gates are satisfied (a staged binary exists, `autoupdate` is on, buffer is clean, `argv0` is writable, the editor has been idle for 60 seconds), the editor first re-verifies the staged binary against the cached signed manifest — it may have sat in the user-writable cache for days — deleting it on any mismatch. It then writes a one-shot resume record, snapshots the running binary to `issy.prev` (recording its SHA-256 in `issy.prev.sha256`), atomically renames the staged binary over its own executable, tears down the terminal, and `execve()`s the new binary with `--resume <path>`. Termios state lives on the tty device, not the file descriptor, so the terminal survives `execve` cleanly — the user sees one re-render.
- **Resume** (`tryResume`): The new binary, when invoked with `--resume <path>`, reads the resume record, verifies it's fresh (<5 min) and that the file's mtime still matches the snapshot, then restores `cursor.line`/`cursor.col` (both clamped to the file's actual dimensions) and shows `upgraded to <sha>` in the footer. Missing or stale records are a safe no-op.
- **Rollback** (`rollback`): `issy --rollback` runs before any TUI init: it verifies `issy.prev` against the checksum recorded at apply time (when present), renames it back over `argv0`, and exits. One-shot, atomic.

All HTTP fetches use bounded `std.Io.Writer.fixed` buffers so a malicious or broken server can't drive memory usage past the per-fetch cap. All failures on the download/verify/stage path are silent and non-fatal — on any error the editor falls back to notify-only and retries on the next run.

### update_key.zig -- Signing Trust Root

Holds the 32-byte Ed25519 public key that the auto-update path verifies `sha256sums.txt.sig` against. Committed to the repo; the matching private key is a GitHub Actions Secret (`UPDATE_SIGNING_KEY`) that only the CI workflow can read. Fresh checkouts start with an all-zero placeholder — `isConfigured()` returns false and the whole signed-download path becomes a no-op until the maintainer runs `zig build keygen` and commits a real key. Forks wanting auto-update for their own releases go through the same bootstrap.

### build_info.zig -- Generated

Written by `build.zig` at configure time via `git rev-parse HEAD` and `git status --porcelain`. On a clean release build (e.g. CI), embeds the full 40-char commit SHA and `build_type = .release`. A dirty tree keeps its real SHA but is marked `build_type = .dev`; only an un-gitted tree (or git failure) falls back to the placeholder `"dev" ++ "0"*37`. Either way, `.dev` is the kill switch the update path checks. Always gitignored — never committed.

### tools/keygen.zig -- Keypair Generator

Standalone program, built and run via `zig build keygen`. Generates a fresh Ed25519 keypair using `std.crypto.sign.Ed25519.KeyPair.generate()`, PKCS#8-wraps the private key into a PEM envelope (for pasting into a GitHub Actions Secret), and prints the matching public key as a Zig byte-array literal (for pasting into `update_key.zig`). The private key never touches disk; the caller is responsible for transferring both halves and then deleting the terminal output.

## Build System

`build.zig` defines:

- **`issy` executable**: Links libc on POSIX targets (for termios). Optimization follows the standard Zig flow — Debug by default, `-Doptimize=ReleaseSafe` for release artifacts (what CI and the installer build).
- **`cross` step**: Builds for all 5 target platforms.
- **`test` step**: Runs test blocks from every source file independently (not via a root test import -- each file is its own test compilation unit).
- **`keygen` step**: Builds and runs `tools/keygen.zig` to print a fresh signing keypair. Used once per repo to bootstrap the auto-update trust root.
- **`writeBuildInfo` (configure-time)**: Runs `git rev-parse HEAD` + `git status --porcelain` to regenerate `src/build_info.zig` with the current commit SHA and build type. Skipped silently if git is unavailable or the tree is dirty (falls back to `dev`).

## macOS distribution

macOS does not ship prebuilt binaries in GitHub releases. Cross-compiled Mach-O from Linux has no `LC_CODE_SIGNATURE` load command and the Apple Silicon kernel refuses to `execve` it. Rather than grow a cross-signing pipeline, macOS users install via a Homebrew formula (`Formula/issy.rb`) that depends on Zig and builds from source, producing a native host-signed binary that just works on both Intel and Apple Silicon.

The formula carries both a stable block (`url` + `sha256` pointing at a tagged source tarball) and a `head` spec. The stable block is regenerated on every `vX.Y.Z` tag push by the `release-tag` job in `.github/workflows/ci.yml`, which downloads the GitHub-generated source tarball, hashes it, and runs `.github/scripts/bump_formula.py` to rewrite the block between its `STABLE_BEGIN`/`STABLE_END` markers, then commits the result back to `main`. Upshot: `brew install issy` / `brew upgrade issy` behave like any other versioned formula, and `brew install --HEAD issy` remains available for users who want to track `main` between tags.

The auto-update worker's `currentAssetName()` in `src/update.zig` returns `null` for macOS, which disables the download/verify/stage codepath on that platform. The notify-only path still runs (reads `commit.txt` from the latest release and compares against `build_info.commit_sha`), so macOS users see the "update available" notice in the footer and run `brew upgrade issy` (or `brew upgrade --fetch-HEAD issy` for HEAD installs) to act on it. CI includes a macOS cross-compile smoke test and a real-macOS homebrew-test job to catch compilation regressions that would break the brew build.

## Design Constraints

- Zero external dependencies. Zig `std` only.
- Single binary. No runtime config files required.
- No allocations in the tokenizer hot path; per-frame render work is O(visible rows), not O(file size).
- Terminal state restored on every exit path: clean quit, panic (custom panic handler runs `term.emergencyRestore()` before the trace prints), and SIGTERM/SIGHUP (handled as a graceful shutdown that also persists the cursor position).
