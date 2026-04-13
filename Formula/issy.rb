class Issy < Formula
  desc "Minimal text editor that looks like a printed page"
  homepage "https://github.com/davidemerson/issy"
  license "ISC"
  head "https://github.com/davidemerson/issy.git", branch: "main"

  depends_on "zig" => :build

  def install
    system "zig", "build", "-Doptimize=ReleaseSafe"
    bin.install "zig-out/bin/issy"
    man1.install "issy.1"
  end

  test do
    assert_match "issy", shell_output("#{bin}/issy --version")
  end
end
