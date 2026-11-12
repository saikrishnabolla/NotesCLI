class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.0/notescli-1.1.0-macos-universal.tar.gz"
  sha256 "f9a70733f551280f5f3646ec8279ff3f6a02bc0927ea4f105832feaa3a85db3f"
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
