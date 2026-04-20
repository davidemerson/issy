class Issy < Formula
  desc "Minimal text editor that looks like a printed page"
  homepage "https://github.com/davidemerson/issy"
  license "BSD-3-Clause"

  # STABLE_BEGIN — populated by .github/workflows/ci.yml on `vX.Y.Z` tag push.
  # Until the first tag lands, this block is empty and the formula is head-only
  # (`brew install --HEAD davidemerson/issy/issy`). Once populated it gains
  # `url` + `sha256`, and plain `brew install` / `brew upgrade issy` work as
  # they do for any versioned formula. Do not edit by hand — edits are
  # overwritten by the release job in .github/scripts/bump_formula.py.
  # STABLE_END
  head "https://github.com/davidemerson/issy.git", branch: "main"

  # Use zig@0.15 (not the unversioned `zig` formula, which is a moving
  # target — Homebrew bumped it to 0.16 and broke our build). zig@0.15
  # is pinned, includes Apple's Xcode 26.4 TBD compatibility patch, and
  # won't move to a new major release. Keep in sync with ZIG_VERSION in
  # .github/workflows/ci.yml; bump both in one commit.
  depends_on "zig@0.15" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe"
    bin.install "zig-out/bin/issy"
    man1.install "issy.1"
  end

  test do
    assert_match "issy", shell_output("#{bin}/issy --version")
  end
end
