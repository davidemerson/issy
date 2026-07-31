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

1. **Check `GH_TAGNAME`** in `issy/Makefile` — it must point at the
   release being submitted. It is the single source of truth for the
   version; the prep script reads it and refuses a mismatched `TAG=`
   override.

2. **Run the prep script** from the repo root:

   ```sh
   bash packaging/openbsd/prep-submission.sh
   ```

   This tags `GH_TAGNAME` on `HEAD` (if the tag doesn't already
   exist), pushes the tag to origin, downloads the GitHub archive,
   computes the base64 SHA256 + byte size, writes them into
   `distinfo`, and builds `packaging/openbsd/issy-port.tar.gz`.
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
under `issy/`, bump `GH_TAGNAME` in `issy/Makefile`, and re-run:

```sh
bash packaging/openbsd/prep-submission.sh
```

The prep script will create the new tag, recompute hashes, and
rebuild the tarball.

## What's inside the port

- **`Makefile`** — Pins to `GH_TAGNAME = v1.3.1` on the upstream
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

- **Verified on a real OpenBSD 7.9 amd64 VM.** issy builds with
  `zig build -Doptimize=ReleaseSafe`, all unit tests pass under
  `zig build test` (258 test blocks; 1321 executions across
  compilation units), and all 16 PTY-based integration suites in
  `tests/run_tests.sh` (63 individual cases) pass. The VM uses
  Zig 0.15.2+e4cbd752c from `pkg_add zig`. CI runs this end-to-end
  via the `openbsd-test` job in `.github/workflows/ci.yml`, using
  `cross-platform-actions/action@v1.3.0` with QEMU/KVM, so any
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

- **zig's build runner honors `DESTDIR` from the environment**
  (std.Build.resolveInstallPrefix), and the ports MAKE_ENV always
  carries `DESTDIR=''` during do-build — without a pinned prefix,
  `zig build` installs the binary into `${DESTDIR}/usr` instead of
  `./zig-out` and `make fake` finds nothing. do-build passes an
  explicit `--prefix ${WRKBUILD}/zig-out` for this reason; don't
  simplify it away. Found the hard way via the port-test workflow.

- **OpenBSD -current ships zig 0.16.0** (since 2026-05-11), while
  7.9-release packages ship 0.15.2. issy ≥ v1.3.1 supports both
  series via src/fsx.zig, so the port builds on -current (where new
  ports are actually committed) and on 7.9 (where the port-test CI
  workflow runs). Do not submit a port of any issy release older
  than v1.3.1 — reviewers on -current cannot build it.

- **The `t14_pdf` integration test at `tests/run_tests.sh`** is
  skipped if no font file is found; in CI on OpenBSD it skips
  cleanly. The Makefile's `do-test` only invokes `zig build test`
  (unit tests), not the shell integration suite, so this should not
  affect the port build either way.
