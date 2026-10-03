cask "ap" do
  version "0.1.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/sadayuki-matsuno/ap/releases/download/v#{version}/Ap-#{version}.zip"
  name "Ap"
  desc "Clipboard ledger for AI agents with a menu bar picker"
  homepage "https://github.com/sadayuki-matsuno/ap"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Ap.app"
  binary "#{appdir}/Ap.app/Contents/MacOS/ap"

  zap trash: [
    "~/Library/Application Support/ap",
    "~/Library/Preferences/com.sadayuki-matsuno.ap.plist",
  ]

  caveats <<~EOS
    Ap is ad-hoc signed (no Apple Developer ID yet), so macOS may block the
    first launch. Allow it in System Settings > Privacy & Security
    ("Open Anyway"), or clear the quarantine flag:

      xattr -dr com.apple.quarantine /Applications/Ap.app

    Enter in the picker pastes into the app you were in. That needs Ap in
    System Settings > Privacy & Security > Accessibility; Ap asks on first
    launch. Until then, Enter copies only.

    To have Claude Code record its copies, add this line to ~/.claude/CLAUDE.md
    (and remove any rule that tells it to use pbcopy):

      When you hand me text to paste (a message, a command, a PR description), pipe it to `ap` instead of pbcopy (`... | ap`), and add `--label "<what it is>"` when the purpose is clear. I paste it from the Ap picker (Control-Command-P).
  EOS
end
