# Multi-cursor rename demo for issy's README.
#
# Opens a small Zig file with three `u8` fields. Ctrl+D selects the word
# under the cursor and adds a cursor at the next occurrence; pressing it
# again keeps adding. Each press arms a rename: the word is highlighted
# at every secondary cursor, and the first character typed replaces it
# everywhere in one shot. Subsequent characters insert at every cursor.
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
# Isolate from the recording user's real ~/.cache/issy (saved cursor
# positions would otherwise change where the file opens).
Type "export HOME=$(mktemp -d)"
Enter
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

# Ctrl+D twice — adds a cursor at the next two occurrences of "u8" and
# arms the rename. The armed word is highlighted at each secondary.
Ctrl+D
Sleep 700ms
Ctrl+D
Sleep 1400ms

# Type the replacement. The first character replaces "u8" at all three
# cursors; the rest insert at all three.
Type "f32"
Sleep 1500ms

# Escape clears extra cursors.
Escape
Sleep 800ms

# Quit without saving (hidden, so the GIF ends on the editor).
Hide
Ctrl+Q
Sleep 400ms
Ctrl+Q
Sleep 400ms
