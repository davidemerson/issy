# Multi-cursor demo for issy's README.
#
# Opens a small Zig file with three `u8` fields, uses Ctrl+D twice to
# add a cursor on each subsequent occurrence of the word under the
# primary cursor, then deletes "u8" at all three positions and types
# "f32" in its place — all three fields are renamed in one shot.
#
# Rebuild with:  vhs assets/multi-cursor.tape

Output assets/multi-cursor.gif

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

# Navigate: Down 3 times (to line 4: "    red: u8,"), then 9 Right to the 'u' of "u8".
Down
Down
Down
Sleep 300ms
Right Right Right Right Right Right Right Right Right
Sleep 800ms

# Ctrl+D twice — adds a cursor at the next two occurrences of "u8".
Ctrl+D
Sleep 500ms
Ctrl+D
Sleep 800ms

# Remove "u8" at all three cursors.
Delete
Delete
Sleep 400ms

# Type the replacement. All three cursors get "f32".
Type "f32"
Sleep 1500ms

# Escape clears extra cursors.
Escape
Sleep 800ms

# Quit without saving.
Ctrl+Q
Sleep 400ms
Ctrl+Q
Sleep 400ms
