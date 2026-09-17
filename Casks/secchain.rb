# Cask for the bannzai/homebrew-tap tap. The version and sha256 below are placeholders: the release
# workflow (.github/workflows/release.yml) attaches a copy with the released version and the DMG's
# checksum to each GitHub release. Publishing steps: documents/macos-distribution.md.
cask "secchain" do
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/bannzai/SecChain/releases/download/v#{version}/SecChain-#{version}.dmg"
  name "SecChain"
  desc "Per-repository secret manager backed by the Keychain"
  homepage "https://github.com/bannzai/SecChain"

  # MACOSX_DEPLOYMENT_TARGET of the macOS app.
  depends_on macos: :sonoma

  app "SecChain.app"
  # The tool embedded in the app, not a separately built binary: only the copy signed inside the app
  # bundle can use SecChain's Keychain items (documents/PROJECT.md, design decision 2).
  binary "#{appdir}/SecChain.app/Contents/Helpers/secchain.app/Contents/MacOS/secchain"

  # Secret values stay in the Keychain on uninstall; zap only removes the app's local state.
  zap trash: [
    "~/Library/Preferences/com.bannzai.SecChain.plist",
    "~/Library/Saved Application State/com.bannzai.SecChain.savedState",
  ]
end
