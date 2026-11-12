class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.0/notescli-1.1.0-macos-universal.tar.gz"
  version "1.1.0"
  sha256 "a7f1797e68feaaf27ed77ab3bd8e239f655de30b09c79eb2545246ff3bbb0f0c"
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
