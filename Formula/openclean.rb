class Openclean < Formula
  desc "Transparent, open-source cleanup for macOS"
  homepage "https://github.com/leoAnimesh/OpenClean"
  license "GPL-3.0-only"
  head "https://github.com/leoAnimesh/OpenClean.git", branch: "main"

  depends_on xcode: ["16.0", :build]
  depends_on macos: :sonoma

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "openclean"
    bin.install ".build/release/openclean"
    (share/"openclean/rules").install Dir["Rules/*.yaml"]
  end

  test do
    assert_match "0.1.0", shell_output("#{bin}/openclean --version")
  end
end
