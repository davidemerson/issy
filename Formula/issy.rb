class Issy < Formula
  desc "Minimal text editor that looks like a printed page"
  homepage "https://github.com/davidemerson/issy"
  license "BSD-3-Clause"

  # STABLE_BEGIN — edited by .github/scripts/bump_formula.py on tag push. Do not edit by hand.
  url "https://github.com/davidemerson/issy/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "a5b47e9d85441d0b25bc892b9cf2bfbff49e7b375bfa181a9eb6280998c29b37"
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
