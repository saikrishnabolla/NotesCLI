class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.0.1/notescli-1.0.1-macos-universal.tar.gz"
  version "1.0.1"
  sha256 "0bc036d83c627dfe590fc10446731a61aaec73a25290cdc5ad91f162fdb672dd"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
