cask "whorl" do
  version "0.2.1"
  sha256 "dfa924c4eb9e6dbc700738e784784900d5084b999e63a4dc3b6af3af67f7ec48"

  url "https://github.com/fenil210-cactus/whorl/releases/download/v#{version}/Whorl.zip"
  name "Whorl"
  desc "Free, local drag-and-drop file converter in the menu bar"
  homepage "https://github.com/fenil210-cactus/whorl"

  depends_on macos: :ventura

  app "Whorl.app"
  binary "#{appdir}/Whorl.app/Contents/MacOS/Whorl", target: "whorl"

  # The app is signed ad hoc (no paid Apple account). Clearing the download flag lets it open without a warning.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Whorl.app"], must_succeed: false
  end

  uninstall quit: "com.fenil210.whorl"

  zap trash: [
    "~/Library/Preferences/com.fenil210.whorl.plist",
    "~/Library/Saved Application State/com.fenil210.whorl.savedState",
  ]
end
