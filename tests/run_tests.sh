#!/usr/bin/env bash
# run_tests.sh -- master test runner for issy
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"
ISSY="$REPO/zig-out/bin/issy"

command -v expect >/dev/null || { echo "ERROR: expect is not installed"; exit 1; }

# Build. A failed build must fail the run — testing a stale binary
# reports results for code that no longer exists.
echo "Building issy..."
if ! (cd "$REPO" && zig build 2>&1); then
    echo "BUILD FAILED"
    exit 1
fi
echo ""

# All suite mktemps land under one trap-cleaned directory, so a suite
# that aborts mid-run (uncaught Tcl error) can't leak temp dirs.
TMPDIR="$(mktemp -d)"
export TMPDIR
trap 'rm -rf "$TMPDIR"' EXIT

PASS=0
FAIL=0
SKIP=0
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

# Expect-based integration tests (redirect spawned process output to
# /dev/null). Exit 77 is the automake skip convention: counted apart
# from PASS so a suite that couldn't run never masquerades as green.
for exp in "$SCRIPT_DIR"/t[0-9][0-9]_*.exp; do
    [ -f "$exp" ] || continue
    name="$(basename "$exp" .exp)"
    echo "--- $name ---"
    expect "$exp" "$ISSY" "$SCRIPT_DIR" 2>&1 >/dev/null
    rc=$?
    if [ $rc -eq 0 ]; then
        PASS=$((PASS + 1))
    elif [ $rc -eq 77 ]; then
        SKIP=$((SKIP + 1))
    else
        FAIL=$((FAIL + 1))
    fi
    TOTAL=$((TOTAL + 1))
    echo ""
done

echo "==============================="
echo "  SUITES: $TOTAL"
echo "  PASS:   $PASS"
echo "  SKIP:   $SKIP"
echo "  FAIL:   $FAIL"
echo "==============================="

[ $FAIL -eq 0 ]
