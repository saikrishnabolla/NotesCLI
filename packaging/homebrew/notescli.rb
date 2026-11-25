class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.16/notescli-1.1.16-macos-universal.tar.gz"
  sha256 "c974118197c8374f0031a3b338dc2aa7f08c5d08f7ab69dc516da9406f6409ac"
  license "MIT"

  depends_on macos: :sonoma

  def install
    bin.install "notescli"
    libexec.install "Notes CLI.app"
  end

  def caveats
    <<~EOS
      Run `notescli onboard` after installation or upgrade. It installs Notes CLI.app
      in ~/Applications, starts it, and resumes permission setup.
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/notescli --version")
  end
end
