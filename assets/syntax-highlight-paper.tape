# Static "paper" theme screenshot for issy's README.
#
# Mirrors syntax-highlight.tape but renders with --theme paper
# (Solarized Light) and uses a matching vhs terminal theme so the
# window padding doesn't clash with the cream background.
#
# Rebuild with:
#   vhs assets/syntax-highlight-paper.tape
#   ffmpeg -y -v error -sseof -1 -i assets/.syntax-highlight-paper-tmp.gif \
#       -frames:v 1 assets/syntax-highlight-paper.png
#   rm assets/.syntax-highlight-paper-tmp.gif

Output assets/.syntax-highlight-paper-tmp.gif

Set Shell "bash"
Set FontSize 14
Set Width 1100
Set Height 700
Set Padding 20
Set Theme "Builtin Solarized Light"

Hide
Type "./zig-out/bin/issy --no-config --theme paper src/editor.zig"
Enter
Sleep 1500ms

PageDown
Sleep 500ms
Show

Sleep 2s

Ctrl+Q
Sleep 300ms
