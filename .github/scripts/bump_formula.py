#!/usr/bin/env python3
# Rewrites the STABLE_BEGIN/END block in Formula/issy.rb to point at a
# specific tag's source tarball and sha256. Idempotent; safe to re-run.
#
# Invoked from .github/workflows/ci.yml on tag push. Not intended for manual
# use — if you run this locally, the next tag-push CI run will overwrite your
# edits.
#
# Usage: bump_formula.py <formula_path> <version> <sha256>
#   version is the bare semver ("0.2.0"), not the tag ("v0.2.0").

import pathlib
import re
import sys

BEGIN = "  # STABLE_BEGIN"
END = "  # STABLE_END"
BLOCK_RE = re.compile(
    r"  # STABLE_BEGIN.*?  # STABLE_END\n",
    re.DOTALL,
)


def render_block(version: str, sha256: str) -> str:
    return (
        f"{BEGIN} — edited by .github/scripts/bump_formula.py on tag push. Do not edit by hand.\n"
        f'  url "https://github.com/davidemerson/issy/archive/refs/tags/v{version}.tar.gz"\n'
        f'  sha256 "{sha256}"\n'
        f"{END}\n"
    )


def main() -> None:
    if len(sys.argv) != 4:
        sys.exit("usage: bump_formula.py <formula_path> <version> <sha256>")
    path = pathlib.Path(sys.argv[1])
    version = sys.argv[2]
    sha256 = sys.argv[3]

    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        sys.exit(f"refusing to write: sha256 {sha256!r} is not 64 hex chars")

    src = path.read_text()
    if not BLOCK_RE.search(src):
        sys.exit(
            f"could not find STABLE_BEGIN/END block in {path} — "
            "is the formula template still intact?"
        )

    new = BLOCK_RE.sub(render_block(version, sha256), src, count=1)
    if new == src:
        print("formula already up to date")
        return
    path.write_text(new)
    print(f"bumped {path} to v{version}")


if __name__ == "__main__":
    main()
