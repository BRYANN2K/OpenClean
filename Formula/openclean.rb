# frozen_string_literal: true

# Homebrew formula for the `openclean` command-line tool. This repository is the tap:
#
#   brew install leoanimesh/openclean/openclean          # the notarized release build
#   brew install --HEAD leoanimesh/openclean/openclean   # build the latest main from source
#
# The stable `url` and `sha256` are bumped by scripts/bump-homebrew.sh, which the release workflow runs
# in a pull request after every release (see CONTRIBUTING.md "Homebrew").
class Openclean < Formula
  desc "Transparent, open-source cleanup for macOS"
  homepage "https://github.com/leoAnimesh/OpenClean"
  url "https://github.com/leoAnimesh/OpenClean/releases/download/v0.3.0/openclean-cli-0.3.0.zip"
  sha256 "9c02cf850d0171402d8b805a4b09f8a272d6a31c42dd59e5f9d2abd419a1e4ce"
  license "GPL-3.0-only"

  livecheck do
    url :stable
    strategy :github_latest
  end

  head do
    url "https://github.com/leoAnimesh/OpenClean.git", branch: "main"
    depends_on xcode: ["16.0", :build]
  end

  depends_on macos: :sonoma

  def install
    if build.head?
      system "swift", "build", "-c", "release", "--disable-sandbox", "--product", "openclean"
      bin.install ".build/release/openclean"
      (share/"openclean/rules").install Dir["Rules/*.yaml"]
    else
      # The release zip (its top-level openclean-cli/ folder is stripped by Homebrew) holds a universal,
      # notarized binary and the rule packs; the CLI finds them in <bin>/../share/openclean/rules.
      bin.install "bin/openclean"
      (share/"openclean/rules").install Dir["share/openclean/rules/*.yaml"]
    end
  end

  test do
    assert_match(/\d+\.\d+\.\d+/, shell_output("#{bin}/openclean --version"))
    assert_match "xcode.derived-data", shell_output("#{bin}/openclean rules list")
  end
end
