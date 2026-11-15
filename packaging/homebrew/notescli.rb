class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.9/notescli-1.1.9-macos-universal.tar.gz"
  sha256 "bbc33726d62446afdbdb30588333108d507d10146df18020cbcec70c5809f0fa"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
    libexec.install "NotesCLI Capability Host.app"
  end

  def caveats
    <<~EOS
      Run `notescli onboard` after installation or upgrade to install the matching capability host.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
