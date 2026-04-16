#!/usr/bin/env bash
# t01_cli.sh -- CLI flag tests (no PTY needed)
set -uo pipefail

ISSY="$1"
PASS=0
FAIL=0

check() {
    local name="$1"
    local ok="$2"
    if [ "$ok" -eq 1 ]; then
        echo "PASS $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL $name"
        FAIL=$((FAIL + 1))
    fi
}

# A1: --version
output=$("$ISSY" --version 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -Eq "issy [0-9]+\.[0-9]+\.[0-9]+"; then
    check "A1_version" 1
else
    check "A1_version" 0
fi

# A2: --help
output=$("$ISSY" --help 2>&1)
rc=$?
if [ $rc -eq 0 ] && echo "$output" | grep -q "Usage:"; then
    check "A2_help" 1
else
    check "A2_help" 0
fi

# A3: non-tty stdin
output=$(echo "" | "$ISSY" 2>&1)
rc=$?
if [ $rc -ne 0 ] && echo "$output" | grep -qi "not a terminal"; then
    check "A3_nontty" 1
else
    check "A3_nontty" 0
fi

echo ""
echo "=== t01_cli: $PASS/$((PASS + FAIL)) passed ==="
[ $FAIL -eq 0 ]
