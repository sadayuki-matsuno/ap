# frozen_string_literal: true

# Homebrew formula for ap (copy to sadayuki-matsuno/homebrew-tap as Formula/ap.rb)
class Ap < Formula
  desc "Clipboard ledger for AI agents: pbcopy that records where each copy came from"
  homepage "https://github.com/sadayuki-matsuno/ap"
  url "https://github.com/sadayuki-matsuno/ap/releases/download/v0.1.0/ap-0.1.0-arm64.tar.gz"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  def install
    bin.install "ap"
  end

  def caveats
    <<~EOS
      To have Claude Code record its copies, replace the pbcopy rule in ~/.claude/CLAUDE.md with:
        When you put text on the clipboard, pipe it to `ap` instead of pbcopy (`... | ap`).
    EOS
  end

  test do
    # brew test may run without a usable pasteboard, so only exercise the database side.
    ENV["AP_DB_PATH"] = (testpath/"ap.db").to_s
    assert_match version.to_s, shell_output("#{bin}/ap --version")
    assert_match "(no history)", shell_output("#{bin}/ap list")
    assert_path_exists testpath/"ap.db"
  end
end
