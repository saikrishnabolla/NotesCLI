class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.0.0/notescli-1.0.0-macos-universal.tar.gz"
  version "1.0.0"
  sha256 "9771de756a0e9b0a3a3180b6f62bbc8f61e2c98dc34ba3f8df62f1e254298d37"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
