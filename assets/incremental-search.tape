# Incremental search demo for issy's README.
#
# Opens src/editor.zig, presses Ctrl+F to enter search mode, types
# a query letter by letter — each keystroke jumps the cursor to the
# first live match. Ctrl+G walks through subsequent matches, Escape
# cancels.
#
# Rebuild with:  vhs assets/incremental-search.tape

Output assets/incremental-search.gif

Set Shell "bash"
Set FontFamily "Berkeley Mono Variable NNIX"
Set FontSize 14
Set Width 1100
Set Height 640
Set Padding 20
Set Theme "Dracula"
Set TypingSpeed 120ms

Hide
Type "./zig-out/bin/issy --no-config src/editor.zig"
Enter
Sleep 1s
Show

Sleep 800ms

# Enter search mode.
Ctrl+F
Sleep 700ms

# Type the query incrementally — each letter re-runs the search and
# jumps the cursor to the first match.
Type "cursor"
Sleep 1500ms

# Walk to the next few matches.
Ctrl+G
Sleep 900ms
Ctrl+G
Sleep 900ms
Ctrl+G
Sleep 1200ms

# Cancel (returns to the original position).
Escape
Sleep 600ms

Ctrl+Q
Sleep 400ms
