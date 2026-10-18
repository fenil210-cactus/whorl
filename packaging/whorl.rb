cask "whorl" do
  version "0.2.0"
  sha256 :no_check # replace with the value in Whorl.zip.sha256 when cutting a release

  url "https://github.com/fenil210-cactus/whorl/releases/download/v#{version}/Whorl.zip"
  name "Whorl"
  desc "Free, local drag-and-drop file converter in the menu bar"
  homepage "https://github.com/fenil210-cactus/whorl"

  depends_on macos: ">= :ventura"

  app "Whorl.app"
  binary "#{appdir}/Whorl.app/Contents/MacOS/Whorl", target: "whorl"

  # The app is signed ad hoc (no paid Apple account). Clearing the download flag lets it open without a warning.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Whorl.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Preferences/com.fenil210.whorl.plist",
    "~/Library/Saved Application State/com.fenil210.whorl.savedState",
  ]
end
