class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.8/notescli-1.1.8-macos-universal.tar.gz"
  sha256 "b61bf2e99710431a8c532a570544f02c248c9dea3507c887911accb66f858507"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
    libexec.install "NotesCLI Capability Host.app"
  end

  def caveats
    <<~EOS
      Run `notescli onboard` after installation or upgrade to install the matching capability host.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
