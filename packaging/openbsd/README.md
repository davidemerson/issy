# OpenBSD port submission

This directory contains everything needed to submit `editors/issy`
to the OpenBSD ports tree via `ports@openbsd.org`.

## Layout

```
packaging/openbsd/
├── issy/
│   ├── Makefile        # port build rules
│   ├── distinfo        # tarball SHA256 + SIZE (filled in by the prep script)
│   └── pkg/
│       ├── DESCR       # long description for `pkg_info`
│       └── PLIST       # list of installed files
├── prep-submission.sh  # tag + hash + tarball generator
├── submission-email.txt # draft email body to ports@openbsd.org
└── README.md           # you are here
```

## Submission workflow

1. **Edit the MAINTAINER line** in `issy/Makefile` — replace
   `REPLACE-WITH-YOUR-EMAIL@example.com` with your real email. The
   prep script will refuse to build the tarball until you do.

2. **Run the prep script** from the repo root:

   ```sh
   bash packaging/openbsd/prep-submission.sh
   ```

   This tags `v0.1.1` on `HEAD`, pushes the tag to origin, downloads
   the GitHub archive, computes the base64 SHA256 + byte size, writes
   them into `distinfo`, and builds `packaging/openbsd/issy-port.tar.gz`.
   It is idempotent — re-running is safe.

3. **Send the email** to `ports@openbsd.org` with the subject
   `NEW: editors/issy`, body from `submission-email.txt`, and the
   `issy-port.tar.gz` tarball attached.

   From macOS Mail:

   ```sh
   open -a Mail "mailto:ports@openbsd.org?subject=NEW:%20editors/issy"
   ```

   Then paste the body from `submission-email.txt` and drag in the
   tarball.

   From a command-line MTA:

   ```sh
   mail -s "NEW: editors/issy" \
        -a packaging/openbsd/issy-port.tar.gz \
        ports@openbsd.org \
        < packaging/openbsd/submission-email.txt
   ```

## Re-cutting a release

If the first submission round needs revisions, iterate on the files
under `issy/`, bump the tag:

```sh
TAG=v0.1.2 bash packaging/openbsd/prep-submission.sh
```

The prep script will create the new tag, recompute hashes, and
rebuild the tarball.

## What's inside the port

- **`Makefile`** — Pins to `GH_TAGNAME = v0.1.1` on the upstream
  repo. Declares `BUILD_DEPENDS = lang/zig`, `WANTLIB += c`,
  `ONLY_FOR_ARCHS = amd64 arm64` (matching lang/zig). Invokes
  `zig build -Doptimize=ReleaseSafe` in `do-build` with
  `ZIG_GLOBAL_CACHE_DIR`/`ZIG_LOCAL_CACHE_DIR` redirected to
  `${WRKBUILD}` so the ports build doesn't write to `$HOME`.
  Runs `zig build test` in `do-test`.

- **`distinfo`** — Starts with placeholder SHA256/SIZE. The prep
  script fills these in with the real base64-encoded hash and byte
  count of the GitHub archive tarball. OpenBSD `distinfo` files
  use base64 SHA256, not hex.

- **`pkg/DESCR`** — Short description of what issy is and does. All
  lines ≤80 columns per OpenBSD convention.

- **`pkg/PLIST`** — Just `bin/issy` and `man/man1/issy.1`, paths
  relative to `${PREFIX}` (typically `/usr/local`).

## Caveats worth knowing before you send

- **This is the first Zig-consumer port in the tree.** `lang/zig`
  itself is CMake-bootstrapped, not zig-built, so there is no in-tree
  precedent for a port that invokes `zig build` in `do-build`. The
  maintainers may ask for a shared `lang/zig` consumer module
  analogous to `lang/go`. The email draft mentions this up front.

- **Verified on a real OpenBSD 7.8 amd64 VM.** Issy builds with
  `zig build -Doptimize=ReleaseSafe`, all 666 unit tests pass under
  `zig build test`, and all 13 PTY-based integration suites in
  `tests/run_tests.sh` (76 individual cases) pass. The VM uses
  Zig 0.15.1+3db960767 from `pkg_add zig`. CI mirrors this
  end-to-end via the `openbsd-test` job in `.github/workflows/ci.yml`,
  using `cross-platform-actions/action@v1.0.0` with QEMU/KVM, so any
  regression that breaks the OpenBSD build will block the merge.

- **The first ports-submission attempt failed** with
  `std.fs.Dir.realpath ... unsupported on this host` because OpenBSD
  doesn't have a `/proc/self/fd/` for Zig's stdlib to readlink against.
  Fixed in `src/editor.zig` and `src/buffer.zig` by switching the
  three call sites to `std.posix.getcwd` and a hand-rolled tmpdir
  path. The CI job above is the regression guard.

- **`build.zig` links libc on OpenBSD** because modern OpenBSD kernels
  SIGKILL binaries that issue raw syscalls outside of libc. Without
  that the port would build but the resulting binary wouldn't execute.
  Mention this in the email if the maintainers ask why WANTLIB
  includes `c` for what looks like a pure-Zig program.

- **The `t14_pdf` integration test at `tests/run_tests.sh`** is
  skipped if no font file is found; in CI on OpenBSD it skips
  cleanly. The Makefile's `do-test` only invokes `zig build test`
  (unit tests), not the shell integration suite, so this should not
  affect the port build either way.
