cask "whorl" do
  version "0.3.0"
  sha256 "f792738f8e3ef3bf2b544b50937383ac1a253728a03bc2808b68569b821a07ec"

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
