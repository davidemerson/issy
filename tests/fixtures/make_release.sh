#!/usr/bin/env bash
# make_release.sh — build a fake issy release directory, byte-identical
# in format to what .github/workflows/ci.yml publishes, signed with a
# throwaway key.
#
# The update path's whole trust chain (signature, commit binding, epoch
# anti-rollback, asset hash) can only be exercised end-to-end against a
# real signed manifest, and the production signing key is a CI secret.
# So tests mint their own deterministic key and serve these directories
# over loopback to a binary built with -Dupdate-pubkey.
#
# Usage:
#   make_release.sh --out DIR --asset PATH [--commit SHA40] [--epoch N]
#                   [--variant NAME]
#
# Variants (each isolates exactly ONE check, and every one is re-signed
# so it fails where intended rather than at the signature):
#   good             stages successfully
#   bad-sig          signature does not verify
#   sig-short        signature is not 64 bytes
#   commit-missing   no "# issy-commit:" header
#   commit-mismatch  header names a different release than commit.txt
#   epoch-missing    no "# issy-manifest-epoch:" header
#   epoch-old        epoch below the cached high-water mark
#   hash-wrong       asset hash does not match the binary
#   asset-missing    no line for this platform's asset
set -eu

OUT=""; ASSET=""; COMMIT="2222222222222222222222222222222222222222"
EPOCH="1700000000"; VARIANT="good"
ASSET_NAME="issy-linux-amd64"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --asset) ASSET="$2"; shift 2 ;;
        --asset-name) ASSET_NAME="$2"; shift 2 ;;
        --commit) COMMIT="$2"; shift 2 ;;
        --epoch) EPOCH="$2"; shift 2 ;;
        --variant) VARIANT="$2"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done
[ -n "$OUT" ] && [ -n "$ASSET" ] || { echo "usage: --out DIR --asset PATH" >&2; exit 1; }

# openssl with -rawin is required to sign Ed25519 the way CI does.
# LibreSSL (macOS/OpenBSD) lacks it; skip rather than fail the suite.
command -v openssl >/dev/null 2>&1 || exit 77
openssl pkeyutl -help 2>&1 | grep -q rawin || exit 77

if command -v sha256sum >/dev/null 2>&1; then SHA256="sha256sum"
elif command -v shasum >/dev/null 2>&1; then SHA256="shasum -a 256"
else exit 77; fi

mkdir -p "$OUT"

# Deterministic keypair from a fixed seed: PKCS#8 prefix + 32 seed bytes.
# Avoids `openssl genpkey` entirely and keeps the public key stable, so a
# test binary can be built with -Dupdate-pubkey ahead of time.
SEED="000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f"
{
    printf '\060\056\002\001\000\060\005\006\003\053\145\160\004\042\004\040'
    # shellcheck disable=SC2059
    printf "$(echo "$SEED" | sed 's/../\\x&/g')"
} | openssl pkey -inform DER -out "$OUT/key.pem" 2>/dev/null
openssl pkey -in "$OUT/key.pem" -pubout -outform DER | tail -c 32 \
    | od -An -tx1 | tr -d ' \n' > "$OUT/pubkey.hex"

cp "$ASSET" "$OUT/$ASSET_NAME"
# The other platforms' assets only need to exist so the manifest has the
# same shape CI produces; their contents are never fetched.
head -c 2048 /dev/urandom > "$OUT/issy-linux-arm64"
head -c 2048 /dev/urandom > "$OUT/issy-openbsd-amd64"

MANIFEST_COMMIT="$COMMIT"
MANIFEST_EPOCH="$EPOCH"
case "$VARIANT" in
    commit-mismatch) MANIFEST_COMMIT="1111111111111111111111111111111111111111" ;;
    epoch-old) MANIFEST_EPOCH="1000000000" ;;
esac

# Exactly ci.yml's layout: two header lines, then `sha256sum issy-*`
# output (two spaces between hash and name, glob/alphabetical order).
{
    [ "$VARIANT" = "commit-missing" ] || echo "# issy-commit: $MANIFEST_COMMIT"
    [ "$VARIANT" = "epoch-missing" ] || echo "# issy-manifest-epoch: $MANIFEST_EPOCH"
} > "$OUT/sha256sums.txt"
( cd "$OUT" && $SHA256 issy-* >> sha256sums.txt )

case "$VARIANT" in
    hash-wrong)
        # Flip one hex digit of our asset's hash.
        sed -i.bak "s/^\(.\)\(.*  $ASSET_NAME\)$/f\2/" "$OUT/sha256sums.txt"
        rm -f "$OUT/sha256sums.txt.bak"
        ;;
    asset-missing)
        grep -v "  $ASSET_NAME\$" "$OUT/sha256sums.txt" > "$OUT/m.tmp"
        mv "$OUT/m.tmp" "$OUT/sha256sums.txt"
        ;;
esac

# Sign AFTER mutating, so each negative variant fails at the check it
# targets rather than at the signature.
openssl pkeyutl -sign -inkey "$OUT/key.pem" -rawin \
    -in "$OUT/sha256sums.txt" -out "$OUT/sha256sums.txt.sig"

case "$VARIANT" in
    bad-sig)
        # Flip the last byte, keeping the length valid.
        size=$(wc -c < "$OUT/sha256sums.txt.sig")
        head -c $((size - 1)) "$OUT/sha256sums.txt.sig" > "$OUT/s.tmp"
        printf '\xff' >> "$OUT/s.tmp"
        mv "$OUT/s.tmp" "$OUT/sha256sums.txt.sig"
        ;;
    sig-short)
        head -c 63 "$OUT/sha256sums.txt.sig" > "$OUT/s.tmp"
        mv "$OUT/s.tmp" "$OUT/sha256sums.txt.sig"
        ;;
esac

# "<sha> <epoch>" — the format ci.yml writes and the client parses.
printf '%s %s\n' "$COMMIT" "$EPOCH" > "$OUT/commit.txt"

echo "PUBKEY=$(cat "$OUT/pubkey.hex")"
echo "VARIANT=$VARIANT"
