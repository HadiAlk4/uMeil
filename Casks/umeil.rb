# The Homebrew cask for uMeil. This repository is its own tap:
#
#   brew tap hadialk4/umeil https://github.com/HadiAlk4/uMeil
#   brew install --cask umeil
#
# Scripts/update-release-files.py sets the version and checksum for each release.
cask "umeil" do
  version "0.9.0"
  sha256 "1881c00fb9f8d4228b6b018df0450958dc53a3c58421a25a469861e8ff95f99c"

  url "https://github.com/HadiAlk4/uMeil/releases/download/v#{version}/uMeil-#{version}.dmg"
  name "uMeil"
  desc "Embedded IDE for the Texas Instruments Tiva TM4C129"
  homepage "https://hadialk4.github.io/uMeil/"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: ">= :sonoma"

  app "uMeil.app"

  zap trash: [
    "~/Library/Application Support/uMeil",
    "~/Library/Caches/io.github.hadialk4.uMeil",
    "~/Library/HTTPStorages/io.github.hadialk4.uMeil",
    "~/Library/Preferences/io.github.hadialk4.uMeil.plist",
    "~/Library/Saved Application State/io.github.hadialk4.uMeil.savedState",
  ]
end
