class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.0.0/notescli-1.0.0-macos-universal.tar.gz"
  version "1.0.0"
  sha256 "ecfca961bedf9f600c244a25eab9fc8bc6c27d7e577c4340396499c64b8e0818"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
