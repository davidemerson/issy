# issy design principles

issy is a text editor that looks like a printed page, not a terminal application.

## Core rules

1. **Whitespace is structure.** The code floats in space. Left padding before line numbers. A gutter gap between numbers and code. A soft right margin — code stops at column 100, the rest is empty background. The screen is mostly empty.

2. **Barely there.** Every UI element earns its place by being nearly invisible. Line numbers are dim. The status bar has no background color. Comments are faint. The cursor line highlight is a 3-5% bg shift. Prompts appear with no labels or decoration.

3. **Two colors pop, the rest recede.** Syntax highlighting uses many defined colors, but most are near-fg luminance. Only keywords and strings get real chromatic contrast. The eye parses structure through gentle luminance shifts, not a rainbow.

4. **No chrome.** No borders, no box-drawing characters, no decorative separators, no splash screen, no help overlay. The empty state is an empty screen with a cursor.

5. **Prompts are ghosts.** Search, command, and confirm prompts appear on the last row with no label, no box, no prefix. The user types and the text appears. When done, it vanishes.

6. **Status is a whisper.** Filename left, line:col right, nothing in between. No labels ("Ln", "Col"), no language name, no encoding, no percentage. Same background as the editor — no stripe.

7. **The cursor line is a band.** A full-width subtle bg shift from edge to edge. Not just the code area — the margins too. It is the only spatial anchor.

8. **Print is a separate world.** PDF output always uses white paper with its own color mapping tuned for ink. It never inherits the dark TUI theme.
