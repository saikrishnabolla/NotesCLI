class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.12/notescli-1.1.12-macos-universal.tar.gz"
  sha256 "cd8f7f898b7e6a9e7b43ad746fc59d14436022f83cfc963c471c7384a73588f6"
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
