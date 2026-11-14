class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.7/notescli-1.1.7-macos-universal.tar.gz"
  sha256 "57126e8287b69df262a95d9c78cc4ea8427684cce3bacbcc6a4bffef79764056"
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
