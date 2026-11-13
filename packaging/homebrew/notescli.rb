class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.6/notescli-1.1.6-macos-universal.tar.gz"
  sha256 "0115c767ca0ec44bb03c5d3b8f23d4384d9eac655d437fd3227f3ecde2e813e4"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
    libexec.install "NotesCLI Capability Host.app"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
