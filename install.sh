#!/usr/bin/env sh
#
# issy installer — downloads a verified prebuilt binary (Linux, OpenBSD)
# or builds from source (macOS, or any platform without a prebuilt), then
# seeds ~/.issyrc and prints a PATH hint if needed.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/davidemerson/issy/main/install.sh | sh
#   sh install.sh --prefix ~/bin
#   sh install.sh --version latest --no-rc
#
# Flags:
#   --prefix DIR    Install dir (default: $HOME/.local/bin)
#   --version VER   Release tag; default "latest"
#   --no-rc         Do not seed ~/.issyrc
#   --help / -h     Show this help

set -eu

DEFAULT_PREFIX="$HOME/.local/bin"
PREFIX="$DEFAULT_PREFIX"
VERSION="latest"
SEED_RC=1
REPO_URL="https://github.com/davidemerson/issy"

# Ed25519 public key that matches src/update_key.zig. Regenerate with
# `sh tools/dump_pubkey.sh` after rotating UPDATE_SIGNING_KEY.
PUBKEY_PEM='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEA0+BfQpAYpL6E8Yqnn4ND6xGu3qHG4UZ1eWZ0TCTstbE=
-----END PUBLIC KEY-----'

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

info() {
    printf '%s\n' "$*"
}

usage() {
    sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --prefix)
                [ $# -ge 2 ] || die "--prefix requires an argument"
                PREFIX="$2"
                shift 2
                ;;
            --prefix=*)
                PREFIX="${1#--prefix=}"
                shift
                ;;
            --version)
                [ $# -ge 2 ] || die "--version requires an argument"
                VERSION="$2"
                shift 2
                ;;
            --version=*)
                VERSION="${1#--version=}"
                shift
                ;;
            --no-rc)
                SEED_RC=0
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

detect_platform() {
    uname_s="$(uname -s 2>/dev/null || echo unknown)"
    uname_m="$(uname -m 2>/dev/null || echo unknown)"

    case "$uname_s" in
        Linux)   OS=linux ;;
        Darwin)  OS=macos ;;
        OpenBSD) OS=openbsd ;;
        *)       die "unsupported OS: $uname_s (issy supports Linux, macOS, OpenBSD)" ;;
    esac

    case "$uname_m" in
        x86_64|amd64)  ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        *)             die "unsupported architecture: $uname_m (issy supports amd64, arm64)" ;;
    esac
}

asset_name_for() {
    # Prebuilt asset names produced by .github/workflows/ci.yml. Keep in
    # sync with src/update.zig `currentAssetName()` — the auto-update path
    # depends on the same filenames.
    case "$1/$2" in
        linux/amd64)   echo "issy-linux-amd64" ;;
        linux/arm64)   echo "issy-linux-arm64" ;;
        openbsd/amd64) echo "issy-openbsd-amd64" ;;
        *)             echo "" ;;   # empty = no prebuilt, fall through to source build
    esac
}

choose_fetcher() {
    if command -v curl >/dev/null 2>&1; then
        FETCH="curl -fsSL --retry 3 --max-time 120 -o"
    elif command -v wget >/dev/null 2>&1; then
        FETCH="wget -q -O"
    else
        die "neither curl nor wget found; install one and retry"
    fi
}

choose_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        SHA256="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        SHA256="shasum -a 256"
    else
        die "neither sha256sum nor shasum found; install one and retry"
    fi
}

release_url() {
    # Build GitHub release download URL. "latest" maps to the /latest/download
    # redirect, anything else uses /download/<tag>/.
    asset="$1"
    if [ "$VERSION" = "latest" ]; then
        echo "$REPO_URL/releases/latest/download/$asset"
    else
        echo "$REPO_URL/releases/download/$VERSION/$asset"
    fi
}

fetch() {
    url="$1"
    dest="$2"
    # shellcheck disable=SC2086
    $FETCH "$dest" "$url" || die "failed to download: $url"
}

verify_signature() {
    manifest="$1"
    signature="$2"
    need_cmd openssl
    pub_tmp="$TMPDIR_/pubkey.pem"
    printf '%s\n' "$PUBKEY_PEM" > "$pub_tmp"
    if ! openssl pkeyutl -verify -pubin -inkey "$pub_tmp" \
            -rawin -sigfile "$signature" -in "$manifest" >/dev/null 2>&1; then
        die "signature verification FAILED for sha256sums.txt — refusing to install"
    fi
}

verify_binary_hash() {
    manifest="$1"
    asset="$2"
    binary="$3"
    # Manifest lines look like: "<hex>  <name>" (sha256sum / shasum format).
    expected="$(awk -v a="$asset" '$2 == a || $2 == "*" a || $2 == "./" a { print $1 }' "$manifest")"
    if [ -z "$expected" ]; then
        die "sha256sums.txt does not list $asset"
    fi
    actual="$($SHA256 "$binary" | awk '{print $1}')"
    if [ "$expected" != "$actual" ]; then
        die "sha256 mismatch for $asset: expected $expected, got $actual"
    fi
}

ensure_prefix_dir() {
    mkdir -p "$PREFIX" || die "failed to create $PREFIX"
    if [ ! -w "$PREFIX" ]; then
        die "$PREFIX is not writable. Use --prefix to pick a different directory, or chmod the target."
    fi
}

install_prebuilt() {
    asset="$1"
    info "downloading $asset from $VERSION release..."
    fetch "$(release_url "$asset")" "$TMPDIR_/$asset"
    fetch "$(release_url "sha256sums.txt")" "$TMPDIR_/sha256sums.txt"
    fetch "$(release_url "sha256sums.txt.sig")" "$TMPDIR_/sha256sums.txt.sig"

    info "verifying Ed25519 signature..."
    verify_signature "$TMPDIR_/sha256sums.txt" "$TMPDIR_/sha256sums.txt.sig"

    info "verifying sha256..."
    verify_binary_hash "$TMPDIR_/sha256sums.txt" "$asset" "$TMPDIR_/$asset"

    info "installing to $PREFIX/issy..."
    install -m 0755 "$TMPDIR_/$asset" "$PREFIX/issy" \
        || die "install failed (check permissions on $PREFIX)"

    INSTALLED_SHA="$($SHA256 "$PREFIX/issy" | awk '{print $1}')"
}

install_from_source() {
    info "no prebuilt binary for $OS/$ARCH — building from source."

    if ! command -v zig >/dev/null 2>&1; then
        cat >&2 <<EOF
error: zig is required to build from source on $OS/$ARCH.

  1. Install Zig 0.15.2 or newer from https://ziglang.org/download/
  2. Ensure 'zig' is on your PATH
  3. Re-run this installer

On macOS you can also use Homebrew:
  brew tap davidemerson/issy https://github.com/davidemerson/issy
  brew install issy
EOF
        exit 1
    fi

    zig_version="$(zig version 2>/dev/null || echo 0.0.0)"
    # Accept 0.15.x and anything newer. Very coarse — just checks the major/minor.
    case "$zig_version" in
        0.15.*|0.16.*|0.17.*|0.18.*|0.19.*|0.2*|1.*)
            ;;
        *)
            die "zig $zig_version is too old; need 0.15.2 or newer"
            ;;
    esac

    src_dir="$TMPDIR_/src"
    if command -v git >/dev/null 2>&1; then
        info "cloning $REPO_URL..."
        git clone --depth 1 "$REPO_URL" "$src_dir" >/dev/null 2>&1 \
            || die "git clone failed"
    else
        info "git not found — fetching source tarball..."
        tarball="$TMPDIR_/issy.tar.gz"
        fetch "$REPO_URL/archive/refs/heads/main.tar.gz" "$tarball"
        mkdir -p "$src_dir"
        tar -xzf "$tarball" -C "$src_dir" --strip-components=1 \
            || die "failed to extract source tarball"
    fi

    info "building (zig build -Doptimize=ReleaseSafe)..."
    ( cd "$src_dir" && zig build -Doptimize=ReleaseSafe >/dev/null ) \
        || die "zig build failed"

    info "installing to $PREFIX/issy..."
    install -m 0755 "$src_dir/zig-out/bin/issy" "$PREFIX/issy" \
        || die "install failed (check permissions on $PREFIX)"

    INSTALLED_SHA="$($SHA256 "$PREFIX/issy" | awk '{print $1}')"
}

seed_rc() {
    [ "$SEED_RC" -eq 1 ] || return 0
    rc="$HOME/.issyrc"
    if [ -e "$rc" ]; then
        info "$rc already exists — leaving it alone."
        return 0
    fi
    cat > "$rc" <<'EOF'
# issy configuration
#
# Every setting is commented out. Uncomment a line to override the
# compiled-in default. Lines starting with # are comments. Unknown keys
# are ignored.

# ── Editing ──

# tab_width = 4
# expand_tabs = true
# auto_indent = true
# auto_close_brackets = false
# auto_detect_indent = true
# scroll_margin = 5

# ── Display ──

# line_numbers = true
# left_padding = 2
# gutter_padding = 3
# word_wrap = true
# right_margin = 100
# cursor_line_bg = true
# cursor_style = bar         # bar, block, or underline
# trailing_whitespace = true
# indent_mismatch = true

# ── Auto-update ──
#
# Release builds check the latest GitHub release on startup. Both keys
# are silent no-ops if the issy binary is not writable by the current
# user (e.g. a root-owned install).

# notify_updates = true      # status-bar "update available" hint
# autoupdate = false         # opt-in: auto-download + verify + in-session re-exec
#                            # Rollback any time with:  issy --rollback

# ── PDF / Print ──

# font_file = "/Library/Fonts/Berkeley Mono Variable.ttf"
# font_size = 10.0
# print_margin_top = 72.0
# print_margin_bottom = 72.0
# print_margin_left = 108.0
# print_margin_right = 72.0

# ── Theme ──
#
# Uncomment one of:
#   [theme.default]    — black background (compiled-in default)
#   [theme.paper]      — Solarized Light
#
# Individual colors (any theme) use #rrggbb:
# bg = "#000000"
# fg = "#b0b8c8"
# keyword = "#c4a0f7"
# string_color = "#a0d06e"
# comment = "#444c5e"
EOF
    info "seeded $rc with commented defaults."
}

print_path_hint() {
    # Only warn if $PREFIX is not already in PATH.
    case ":$PATH:" in
        *":$PREFIX:"*) return 0 ;;
    esac
    # Guess the user's shell rc for a targeted hint. These are display
    # strings, not paths we read — keep the literal "~" so the user sees
    # something they can copy-paste.
    # shellcheck disable=SC2088
    {
        shell_rc='~/.profile'
        case "${SHELL:-}" in
            */zsh)  shell_rc='~/.zshrc' ;;
            */bash) shell_rc='~/.bashrc' ;;
            */fish) shell_rc='~/.config/fish/config.fish' ;;
        esac
    }
    info ""
    info "note: $PREFIX is not in your PATH. Add it with:"
    if [ "${SHELL##*/}" = "fish" ]; then
        info "  fish_add_path $PREFIX"
    else
        info "  echo 'export PATH=\"$PREFIX:\$PATH\"' >> $shell_rc"
        info "  # then restart your shell, or:  source $shell_rc"
    fi
}

main() {
    parse_args "$@"
    detect_platform
    choose_fetcher
    choose_sha256
    ensure_prefix_dir

    TMPDIR_="$(mktemp -d 2>/dev/null || mktemp -d -t issy-install)"
    trap 'rm -rf "$TMPDIR_"' EXIT INT TERM

    asset="$(asset_name_for "$OS" "$ARCH")"
    if [ -n "$asset" ]; then
        install_prebuilt "$asset"
    else
        install_from_source
    fi

    seed_rc

    info ""
    info "installed issy to $PREFIX/issy"
    info "  sha256: $INSTALLED_SHA"
    print_path_hint
    info ""
    info "Run 'issy --help' to see options."
}

main "$@"
