class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.5/notescli-1.1.5-macos-universal.tar.gz"
  sha256 "b9a782bb8080e85e103b80911fa99ac1f79e640f268c0b1dade193b34f8be3c0"
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
