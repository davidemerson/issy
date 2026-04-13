#!/usr/bin/env bash
# Prepare an OpenBSD ports submission tarball for editors/issy.
#
# What this script does (idempotent — safe to re-run):
#   1. Creates the v0.1.0 git tag on HEAD if it does not already exist
#      locally, and pushes it to origin.
#   2. Downloads the GitHub archive tarball for that tag.
#   3. Computes the base64 SHA256 and byte size of the tarball and
#      writes them into packaging/openbsd/issy/distinfo, replacing
#      the placeholder values.
#   4. Warns if the Makefile still contains the placeholder MAINTAINER
#      email and exits non-zero if so.
#   5. Creates a gzipped tarball of packaging/openbsd/issy/ (the
#      port directory itself) at packaging/openbsd/issy-port.tar.gz
#      ready to attach to the ports@openbsd.org submission email.
#
# Usage (from the repo root):
#   bash packaging/openbsd/prep-submission.sh
#
# If you need to re-cut the release at a different tag, override:
#   TAG=v0.1.1 bash packaging/openbsd/prep-submission.sh

set -euo pipefail

TAG="${TAG:-v0.1.0}"
VERSION="${TAG#v}"
DISTNAME="issy-${VERSION}"
REPO_URL="https://github.com/davidemerson/issy"
ARCHIVE_URL="${REPO_URL}/archive/refs/tags/${TAG}.tar.gz"

REPO_ROOT="$(git rev-parse --show-toplevel)"
PORT_DIR="${REPO_ROOT}/packaging/openbsd/issy"
DISTINFO="${PORT_DIR}/distinfo"
MAKEFILE="${PORT_DIR}/Makefile"
OUT_TARBALL="${REPO_ROOT}/packaging/openbsd/issy-port.tar.gz"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

cd "$REPO_ROOT"

# --- Step 1: tag and push -------------------------------------------

if git rev-parse --verify --quiet "refs/tags/${TAG}" >/dev/null; then
    say "tag ${TAG} already exists locally — skipping tag creation"
else
    say "creating tag ${TAG} on HEAD ($(git rev-parse --short HEAD))"
    printf 'About to run: git tag -a %s -m "Release %s"  &&  git push origin %s\nContinue? [y/N] ' \
        "$TAG" "$VERSION" "$TAG"
    read -r reply
    case "$reply" in
        y|Y) ;;
        *) die "aborted by user" ;;
    esac
    git tag -a "$TAG" -m "Release ${VERSION}"
    git push origin "$TAG"
fi

# Push the tag to origin if it's not already there (second run case).
if ! git ls-remote --tags origin "refs/tags/${TAG}" | grep -q "refs/tags/${TAG}$"; then
    say "pushing ${TAG} to origin"
    git push origin "$TAG"
fi

# --- Step 2: download the archive -----------------------------------

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

say "downloading ${ARCHIVE_URL}"
curl -fsSL -o "${TMPDIR}/${DISTNAME}.tar.gz" "$ARCHIVE_URL"

# --- Step 3: compute hash + size, rewrite distinfo ------------------

SHA256_B64="$(openssl dgst -sha256 -binary "${TMPDIR}/${DISTNAME}.tar.gz" | openssl base64)"
SIZE="$(wc -c < "${TMPDIR}/${DISTNAME}.tar.gz" | tr -d ' ')"

say "SHA256 (base64): ${SHA256_B64}"
say "SIZE:            ${SIZE} bytes"

cat > "$DISTINFO" <<EOF
SHA256 (${DISTNAME}.tar.gz) = ${SHA256_B64}
SIZE (${DISTNAME}.tar.gz) = ${SIZE}
EOF

say "wrote ${DISTINFO}"

# --- Step 4: maintainer placeholder check ---------------------------

if grep -q 'REPLACE-WITH-YOUR-EMAIL' "$MAKEFILE"; then
    printf '\n'
    printf 'warning: %s still contains the MAINTAINER placeholder.\n' "$MAKEFILE"
    printf '         Edit it to your real email before sending to ports@openbsd.org.\n'
    printf '         Then re-run this script to regenerate the tarball.\n\n'
    exit 1
fi

# --- Step 5: build the submission tarball ---------------------------

say "creating submission tarball at ${OUT_TARBALL}"
(
    cd "${REPO_ROOT}/packaging/openbsd"
    tar czf "$OUT_TARBALL" issy/
)

say "submission tarball ready:"
ls -lh "$OUT_TARBALL"

printf '\n'
printf 'Next step: send ports@openbsd.org a new-port submission. A draft\n'
printf 'email body lives at packaging/openbsd/submission-email.txt.\n'
printf '\n'
printf 'Suggested attachment command (macOS mail, edit to taste):\n'
printf '    open -a Mail "mailto:ports@openbsd.org?subject=NEW:%%20editors/issy"\n'
printf '\n'
printf 'Or from the command line with a local MTA:\n'
printf '    cat packaging/openbsd/submission-email.txt | mail -s "NEW: editors/issy" \\\n'
printf '        -a "%s" ports@openbsd.org\n' "$OUT_TARBALL"
