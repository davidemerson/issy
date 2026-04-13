# Static syntax-highlighting screenshot for issy's README.
#
# Opens issy on src/editor.zig, renders a single frame, and exits.
# vhs has no native PNG output, so we render a throwaway GIF to /tmp
# and extract a single frame afterwards with ffmpeg.
#
# Rebuild with:
#   vhs assets/syntax-highlight.tape
#   ffmpeg -y -v error -sseof -1 -i assets/.syntax-highlight-tmp.gif \
#       -frames:v 1 assets/syntax-highlight.png
#   rm assets/.syntax-highlight-tmp.gif

Output assets/.syntax-highlight-tmp.gif

Set Shell "bash"
Set FontSize 14
Set Width 1100
Set Height 700
Set Padding 20
Set Theme "Dracula"

Hide
Type "./zig-out/bin/issy --no-config src/editor.zig"
Enter
Sleep 1500ms

# Page down a bit so we're not on the copyright header — land on
# the Editor struct definition where keywords, types, strings, and
# comments all share the frame.
PageDown
Sleep 500ms
Show

Sleep 2s

Ctrl+Q
Sleep 300ms
