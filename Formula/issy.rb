class Issy < Formula
  desc "Minimal text editor that looks like a printed page"
  homepage "https://github.com/davidemerson/issy"
  license "ISC"
  head "https://github.com/davidemerson/issy.git", branch: "main"

  # Pinned Zig toolchain fetched directly from ziglang.org. We intentionally
  # do NOT `depends_on "zig"` — that's a moving target and Homebrew bumping
  # its zig formula to a new release has broken this build. Official
  # ziglang.org tarballs also bundle LLVM statically, avoiding a ~400 MB
  # llvm@21 dependency on every upgrade. Keep this version in sync with
  # ZIG_VERSION in .github/workflows/ci.yml; bump both in one commit.
  resource "zig" do
    on_macos do
      on_arm do
        url "https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz"
        sha256 "3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b"
      end
      on_intel do
        url "https://ziglang.org/download/0.15.2/zig-x86_64-macos-0.15.2.tar.xz"
        sha256 "375b6909fc1495d16fc2c7db9538f707456bfc3373b14ee83fdd3e22b3d43f7f"
      end
    end
  end

  def install
    zig_dir = buildpath/"zig-toolchain"
    resource("zig").stage(zig_dir)
    zig = zig_dir/"zig"

    # A prebuilt zig from ziglang.org auto-detects the macOS SDK via
    # `xcrun --show-sdk-path`, which Homebrew's superenv intercepts. Without
    # SDKROOT set, the linker falls back to zig's bundled libSystem.tbd stub
    # which is incomplete — native builds fail with undefined libc symbols
    # (_malloc, _sigaction, _waitpid, …). Point zig at the real SDK.
    ENV["SDKROOT"] = MacOS.sdk_path.to_s if OS.mac?

    system zig, "build", "-Doptimize=ReleaseSafe"
    bin.install "zig-out/bin/issy"
    man1.install "issy.1"
  end

  test do
    assert_match "issy", shell_output("#{bin}/issy --version")
  end
end
