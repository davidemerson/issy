# Path completion demo for issy's README.
#
# Launches issy with no file, presses Ctrl+O to enter the open-file
# prompt (seeded with the current working directory), types partial
# names and uses Tab to complete the directory and filename, then
# Enter to open the resolved file.
#
# Rebuild with:  vhs assets/path-completion.tape

Output assets/path-completion.gif

Set Shell "bash"
Set FontSize 14
Set Width 1000
Set Height 520
Set Padding 20
Set Theme "Dracula"
Set TypingSpeed 80ms

Hide
Type "./zig-out/bin/issy --no-config"
Enter
Sleep 800ms
Show

Sleep 800ms

# Open the file prompt.
Ctrl+O
Sleep 1s

# Type a partial directory name.
Type "sr"
Sleep 500ms

# Tab completes it to "src/".
Tab
Sleep 800ms

# Type a partial filename inside src/.
Type "ed"
Sleep 500ms

# Tab completes it to "editor.zig".
Tab
Sleep 1200ms

# Open the resolved file.
Enter
Sleep 2s

# Quit cleanly.
Ctrl+Q
Sleep 500ms
