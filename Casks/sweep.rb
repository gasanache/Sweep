cask "sweep" do
  version "1.0.2"
  sha256 "a53d09c9e795f2c41dbecb246e64f139e4fd44674100d99e90869f6345fd4d73"

  url "https://github.com/gasanache/Sweep/releases/download/v#{version}/Sweep-#{version}.dmg",
      verified: "github.com/gasanache/Sweep/"
  name "Sweep"
  desc "App cleaner, uninstaller and storage explorer"
  homepage "https://github.com/gasanache/Sweep"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Sweep.app"

  # Optional settings and cache cleanup when uninstalling with --zap.
  zap trash: [
    "~/Library/Application Support/com.gasanache.sweep",
    "~/Library/Caches/com.gasanache.sweep",
    "~/Library/HTTPStorages/com.gasanache.sweep",
    "~/Library/Preferences/com.gasanache.sweep.plist",
    "~/Library/Saved Application State/com.gasanache.sweep.savedState",
  ]
end
