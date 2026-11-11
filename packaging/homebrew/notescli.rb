class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.0.0/notescli-1.0.0-macos-universal.tar.gz"
  version "1.0.0"
  sha256 "84c4a1a7bb5d1899107140a7201943beadee4f2cdd5046ba57de7f79bdfab719"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
