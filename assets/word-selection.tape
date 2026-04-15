# Keyboard selection demo for issy's README.
#
# Opens a demo Zig file and shows the selection primitives added in
# the mouse/selection upgrade: Ctrl+Shift+Right extends the selection
# by a word at a time, Shift+Right extends by a character, Ctrl+C
# copies, Ctrl+V pastes. All strictly keyboard-driven so it records
# cleanly under vhs (which has no mouse primitive).
#
# Rebuild with:  vhs assets/word-selection.tape

Output assets/word-selection.gif

Set Shell "bash"
Set FontFamily "Berkeley Mono Variable NNIX"
Set FontSize 16
Set Width 900
Set Height 520
Set Padding 20
Set Theme "Dracula"
Set TypingSpeed 70ms

Hide
Type "./zig-out/bin/issy --no-config assets/demo/palette.zig"
Enter
Sleep 800ms
Show

Sleep 1s

# Land on line 10 ("    .red = 255,") at column 0.
Down 9
Sleep 400ms

# Ctrl+Shift+Right four times — selection grows by a word each press:
#   .   → .red   → .red =   → .red = 255   → .red = 255,
Ctrl+Shift+Right
Sleep 600ms
Ctrl+Shift+Right
Sleep 600ms
Ctrl+Shift+Right
Sleep 600ms
Ctrl+Shift+Right
Sleep 1200ms

# Ctrl+Shift+Left twice — shrink back to just ".red =".
Ctrl+Shift+Left
Sleep 500ms
Ctrl+Shift+Left
Sleep 900ms

# Escape clears the selection and lets the viewer see the effect.
Escape
Sleep 800ms

# Quit without saving.
Ctrl+Q
Sleep 300ms
Ctrl+Q
Sleep 300ms
