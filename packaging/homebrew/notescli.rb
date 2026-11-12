class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.0.3/notescli-1.0.3-macos-universal.tar.gz"
  version "1.0.3"
  sha256 "8b7924a7b816dae0ef6cd4bba9b65f9743633aef7d15f8f2890957c02d7005f1"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
