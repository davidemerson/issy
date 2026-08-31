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

# Everything past this point runs against a scratch HOME. Two separate
# leaks made that necessary: a clean tree stamps build_type=.release, so
# every spawned editor forks an update worker that fetches from
# github.com and rewrites ~/.cache/issy/commit.txt; and every suite
# writes ~/.cache/issy/positions.txt. A test run must not touch the
# developer's (or CI's) real state, and must not depend on the network.
# The build above deliberately ran with the real HOME so zig's global
# cache is reused; suites that need it back read ISSY_TESTS_REAL_HOME.
export ISSY_TESTS_REAL_HOME="$HOME"
REAL_CACHE_FINGERPRINT="$(find "$HOME/.cache/issy" -type f -printf '%p %s %T@\n' 2>/dev/null | sort)"
export HOME="$TMPDIR/home"
mkdir -p "$HOME"
# Belt and braces: current suites all pass --no-config, so this is only
# read by suites that deliberately omit it.
printf 'notify_updates = false\nautoupdate = false\n' > "$HOME/.issyrc"

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

# Isolation check: no suite may touch the developer's real update cache.
# A suite that regresses on this would otherwise fail silently and start
# depending on network state again.
NOW_FINGERPRINT="$(find "$ISSY_TESTS_REAL_HOME/.cache/issy" -type f -printf '%p %s %T@\n' 2>/dev/null | sort)"
if [ "$NOW_FINGERPRINT" != "$REAL_CACHE_FINGERPRINT" ]; then
    echo "ISOLATION FAILURE: the suite modified $ISSY_TESTS_REAL_HOME/.cache/issy"
    FAIL=$((FAIL + 1))
fi

echo "==============================="
echo "  SUITES: $TOTAL"
echo "  PASS:   $PASS"
echo "  SKIP:   $SKIP"
echo "  FAIL:   $FAIL"
echo "==============================="

[ $FAIL -eq 0 ]
