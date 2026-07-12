class Issy < Formula
  desc "Minimal text editor that looks like a printed page"
  homepage "https://github.com/davidemerson/issy"
  license "BSD-3-Clause"

  # STABLE_BEGIN — edited by .github/scripts/bump_formula.py on tag push. Do not edit by hand.
  url "https://github.com/davidemerson/issy/archive/refs/tags/v1.2.0.tar.gz"
  sha256 "f102fc5fa3c7234c18b164463b01fc6bdfb4f1b2219c5296a8acb6e34955b058"
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
