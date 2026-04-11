#!/usr/bin/env bash
# run_tests.sh -- master test runner for issy
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
ISSY="$REPO/zig-out/bin/issy"

# Build
echo "Building issy..."
cd "$REPO" && zig build 2>&1
echo ""

PASS=0
FAIL=0
TOTAL=0

# CLI tests (shell, no PTY)
echo "--- t01_cli ---"
if bash "$SCRIPT_DIR/t01_cli.sh" "$ISSY" 2>&1; then
    PASS=$((PASS + 1))
else
    FAIL=$((FAIL + 1))
fi
TOTAL=$((TOTAL + 1))
echo ""

# Expect-based integration tests (redirect spawned process output to /dev/null)
for exp in "$SCRIPT_DIR"/t[0-9][0-9]_*.exp; do
    [ -f "$exp" ] || continue
    name="$(basename "$exp" .exp)"
    echo "--- $name ---"
    if expect "$exp" "$ISSY" "$SCRIPT_DIR" 2>&1 >/dev/null; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))
    echo ""
done

echo "==============================="
echo "  SUITES: $TOTAL"
echo "  PASS:   $PASS"
echo "  FAIL:   $FAIL"
echo "==============================="

[ $FAIL -eq 0 ]
