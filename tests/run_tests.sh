#!/usr/bin/env bash
# run_tests.sh -- master test runner for issy
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$SCRIPT_DIR")"

command -v expect >/dev/null || { echo "ERROR: expect is not installed"; exit 1; }

# All suite mktemps land under one trap-cleaned directory, so a suite
# that aborts mid-run (uncaught Tcl error) can't leak temp dirs. The
# trap also restores src/update_config.zig, which the seam-enabled build
# below rewrites (a plain `zig build` resets it to all-null).
TMPDIR="$(mktemp -d)"
export TMPDIR
SUITE_PREFIX="$TMPDIR/prefix"
trap 'cd "$REPO" && zig build --prefix "$TMPDIR/heal" >/dev/null 2>&1; rm -rf "$TMPDIR"' EXIT

# Build. A failed build must fail the run — testing a stale binary
# reports results for code that no longer exists.
#
# The suite binary is built with the update origin pointed at a closed
# port and installed OUTSIDE zig-out. Two reasons: the update worker can
# then never reach github.com from a test (it fails instantly on
# connect), and a developer's zig-out/bin/issy is never replaced by a
# binary carrying test-only overrides. Suites that need a real origin
# build their own binary.
echo "Building issy..."
if ! (cd "$REPO" && zig build --prefix "$SUITE_PREFIX" -Dupdate-base-url=http://127.0.0.1:9/ 2>&1); then
    echo "BUILD FAILED"
    exit 1
fi
ISSY="$SUITE_PREFIX/bin/issy"
echo ""

# Everything past this point runs against a scratch HOME. Two separate
# leaks made that necessary: a clean tree stamps build_type=.release, so
# every spawned editor forks an update worker that fetches from
# github.com and rewrites ~/.cache/issy/commit.txt; and every suite
# writes ~/.cache/issy/positions.txt. A test run must not touch the
# developer's (or CI's) real state, and must not depend on the network.
# The build above deliberately ran with the real HOME so zig's global
# cache is reused; suites that need it back read ISSY_TESTS_REAL_HOME.
export ISSY_TESTS_REAL_HOME="$HOME"
# `find -printf` is GNU-only; ls -l is portable enough to notice any
# change to the real cache.
REAL_CACHE_FINGERPRINT="$(ls -l "$HOME/.cache/issy" 2>/dev/null | sort)"
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
NOW_FINGERPRINT="$(ls -l "$ISSY_TESTS_REAL_HOME/.cache/issy" 2>/dev/null | sort)"
if [ "$NOW_FINGERPRINT" != "$REAL_CACHE_FINGERPRINT" ]; then
    echo "ISOLATION FAILURE: the suite modified $ISSY_TESTS_REAL_HOME/.cache/issy"
    FAIL=$((FAIL + 1))
fi

# A shipped binary must never carry the test-only update overrides.
if [ -x "$REPO/zig-out/bin/issy" ] && "$REPO/zig-out/bin/issy" --version 2>/dev/null | grep -q "test-update"; then
    echo "ISOLATION FAILURE: zig-out/bin/issy carries test update overrides"
    FAIL=$((FAIL + 1))
fi

echo "==============================="
echo "  SUITES: $TOTAL"
echo "  PASS:   $PASS"
echo "  SKIP:   $SKIP"
echo "  FAIL:   $FAIL"
echo "==============================="

[ $FAIL -eq 0 ]
