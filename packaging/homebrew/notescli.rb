class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.0.2/notescli-1.0.2-macos-universal.tar.gz"
  version "1.0.2"
  sha256 "8ac8ae0bea4f6650491f10b6a834642e0279ef9a7eeafb32cd8de217e359e015"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
