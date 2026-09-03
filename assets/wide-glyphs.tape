# Static wide-glyph screenshot for issy's README.
#
# Opens a Markdown file mixing CJK, Hangul, emoji, and combining marks
# in a table. issy measures display width per codepoint, so the table
# columns line up on screen.
#
# Rebuild with:
#   vhs assets/wide-glyphs.tape
#   ffmpeg -y -v error -sseof -1 -i assets/.wide-glyphs-tmp.gif \
#       -frames:v 1 assets/wide-glyphs.png
#   rm assets/.wide-glyphs-tmp.gif

Output assets/.wide-glyphs-tmp.gif

Set Shell "bash"
Set FontFamily "Berkeley Mono Variable NNIX"
Set FontSize 14
Set Width 1000
Set Height 560
Set Padding 20
Set Theme "Dracula"

Hide
# Isolate from the recording user's real ~/.cache/issy (saved cursor
# positions would otherwise change where the file opens).
Type "export HOME=$(mktemp -d)"
Enter
Type "./zig-out/bin/issy --no-config assets/demo/unicode.md"
Enter
Sleep 1500ms
Show

Sleep 2s

Hide
Ctrl+Q
Sleep 300ms
