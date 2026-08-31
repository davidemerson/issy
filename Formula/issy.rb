class Issy < Formula
  desc "Minimal text editor that looks like a printed page"
  homepage "https://github.com/davidemerson/issy"
  license "BSD-3-Clause"

  # STABLE_BEGIN — edited by .github/scripts/bump_formula.py on tag push. Do not edit by hand.
  url "https://github.com/davidemerson/issy/archive/refs/tags/v1.4.0.tar.gz"
  sha256 "83f23d34643e8d4b8a7e34d6161f6fabadc31e51713c7182cde0fb2a195a220b"
  # Commit the stable tarball was cut from. The GitHub source archive has
  # no .git, so build.zig can't derive the SHA; passing it via -Dcommit
  # stamps build_info so `issy --version` shows the real commit and the
  # update-notify check runs (a "dev" stamp would silently disable it).
  # A method (not a constant) avoids "already initialized constant"
  # warnings when Homebrew reloads the formula in one process.
  def stable_commit
    "e7bb717638628a02129cf78b6bda678a4d166961"
  end
  # STABLE_END
  head "https://github.com/davidemerson/issy.git", branch: "main"

  # Use zig@0.15 (not the unversioned `zig` formula, which is a moving
  # target — Homebrew bumped it to 0.16 and broke our build). zig@0.15
  # is pinned, includes Apple's Xcode 26.4 TBD compatibility patch, and
  # won't move to a new major release. Keep in sync with ZIG_VERSION in
  # .github/workflows/ci.yml; bump both in one commit.
  depends_on "zig@0.15" => :build

  def install
    args = ["-Doptimize=ReleaseSafe"]
    # HEAD installs clone the repo, so build.zig reads the commit + clean
    # status from git itself. The stable tarball has no .git, so hand it
    # the recorded release commit and mark it a release build.
    unless build.head?
      args << "-Dcommit=#{stable_commit}"
      args << "-Drelease=true"
      # Without the commit timestamp the update path can't tell a newer
      # release from a merely different one, so it declines to auto-apply.
      args << "-Dcommit-epoch=#{stable_commit_epoch}" if respond_to?(:stable_commit_epoch)
    end
    system "zig", "build", *args
    bin.install "zig-out/bin/issy"
    man1.install "issy.1"
  end

  test do
    # Stable builds must report the real version and a non-dev build type
    # (so the update-notify path is active); HEAD builds just report "issy".
    out = shell_output("#{bin}/issy --version")
    assert_match "issy", out
    assert_match version.to_s, out unless build.head?
  end
end
