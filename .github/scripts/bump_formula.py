#!/usr/bin/env python3
# Rewrites the STABLE_BEGIN/END block in Formula/issy.rb to point at a
# specific tag's source tarball and sha256. Idempotent; safe to re-run.
#
# Invoked from .github/workflows/ci.yml on tag push. Not intended for manual
# use — if you run this locally, the next tag-push CI run will overwrite your
# edits.
#
# Usage: bump_formula.py <formula_path> <version> <sha256> <commit>
#   version is the bare semver ("0.2.0"), not the tag ("v0.2.0").
#   commit is the 40-char SHA the tag points at, recorded so the brew
#   stable build can stamp build_info (the source tarball has no .git).

import pathlib
import re
import sys

BEGIN = "  # STABLE_BEGIN"
END = "  # STABLE_END"
BLOCK_RE = re.compile(
    r"  # STABLE_BEGIN.*?  # STABLE_END\n",
    re.DOTALL,
)


def render_block(version: str, sha256: str, commit: str) -> str:
    return (
        f"{BEGIN} — edited by .github/scripts/bump_formula.py on tag push. Do not edit by hand.\n"
        f'  url "https://github.com/davidemerson/issy/archive/refs/tags/v{version}.tar.gz"\n'
        f'  sha256 "{sha256}"\n'
        "  # Commit the stable tarball was cut from. The GitHub source archive has\n"
        "  # no .git, so build.zig can't derive the SHA; passing it via -Dcommit\n"
        "  # stamps build_info so `issy --version` shows the real commit and the\n"
        "  # update-notify check runs (a \"dev\" stamp would silently disable it).\n"
        f'  STABLE_COMMIT = "{commit}".freeze\n'
        f"{END}\n"
    )


def main() -> None:
    if len(sys.argv) != 5:
        sys.exit("usage: bump_formula.py <formula_path> <version> <sha256> <commit>")
    path = pathlib.Path(sys.argv[1])
    version = sys.argv[2]
    sha256 = sys.argv[3]
    commit = sys.argv[4]

    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        sys.exit(f"refusing to write: sha256 {sha256!r} is not 64 hex chars")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        sys.exit(f"refusing to write: commit {commit!r} is not 40 hex chars")

    src = path.read_text()
    if not BLOCK_RE.search(src):
        sys.exit(
            f"could not find STABLE_BEGIN/END block in {path} — "
            "is the formula template still intact?"
        )

    new = BLOCK_RE.sub(render_block(version, sha256, commit), src, count=1)
    if new == src:
        print("formula already up to date")
        return
    path.write_text(new)
    print(f"bumped {path} to v{version}")


if __name__ == "__main__":
    main()
