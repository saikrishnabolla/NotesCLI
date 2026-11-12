class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.0.0/notescli-1.0.0-macos-universal.tar.gz"
  version "1.0.0"
  sha256 "141359f3e9311f1ceb55e10cc3cf4ec1a72709de27769b83b0e45ff8d1860c70"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
