#!/usr/bin/env bash
# Regenerate assets/pdf-export.png from a fresh issy PDF render.
#
# issy's --print mode renders the editor content as a real PDF 1.4 file
# with TTF/OTF font embedding. We render src/editor.zig to a PDF, then
# use pdftoppm to rasterize the first page to PNG for the README.
#
# Dependencies:
#   - A monospace TTF/OTF font (override FONT below if yours differs)
#   - pdftoppm (brew install poppler)
#
# Run from the repo root:  bash assets/pdf-export.sh

set -eu

FONT="${FONT:-/Users/david/Library/Fonts/Berkeley Mono Variable NNIX.ttf}"
INPUT="${INPUT:-src/editor.zig}"
OUT="${OUT:-assets/pdf-export.png}"

if [ ! -f "$FONT" ]; then
    echo "error: font not found at $FONT" >&2
    echo "       set FONT to a TTF/OTF path and re-run" >&2
    exit 1
fi

if ! command -v pdftoppm >/dev/null 2>&1; then
    echo "error: pdftoppm not installed (brew install poppler)" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

./zig-out/bin/issy --no-config --font "$FONT" --print "$TMP/export.pdf" "$INPUT"
pdftoppm -png -r 150 -f 1 -l 1 "$TMP/export.pdf" "$TMP/page"
cp "$TMP/page-01.png" "$OUT"
echo "Wrote $OUT"
