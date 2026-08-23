cask "sweep" do
  version "1.0.1"
  sha256 "60a31aef81bbc39e21fc4410dea176eb56fb36b0bc7e87de2cc06ca451a90d83"

  url "https://github.com/gasanache/Sweep/releases/download/v#{version}/Sweep-#{version}.dmg",
      verified: "github.com/gasanache/Sweep/"
  name "Sweep"
  desc "Cleaner and uninstaller that moves files to the Trash, never deletes"
  homepage "https://github.com/gasanache/Sweep"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sequoia

  app "Sweep.app"

  # Sweep is unsandboxed by necessity and writes only to these locations.
  # Everything it puts in the Trash stays there; nothing here is destructive.
  zap trash: [
    "~/Library/Application Support/com.gasanache.sweep",
    "~/Library/Caches/com.gasanache.sweep",
    "~/Library/HTTPStorages/com.gasanache.sweep",
    "~/Library/Preferences/com.gasanache.sweep.plist",
    "~/Library/Saved Application State/com.gasanache.sweep.savedState",
  ]
end
