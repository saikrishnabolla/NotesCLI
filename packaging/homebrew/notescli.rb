class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.2/notescli-1.1.2-macos-universal.tar.gz"
  sha256 "a51f9f18c5dd0a4bc4f4155b5180e33dd545056234a78c79c02b81f1e88bb579"
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
