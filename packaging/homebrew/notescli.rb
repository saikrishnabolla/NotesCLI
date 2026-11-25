class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.15/notescli-1.1.15-macos-universal.tar.gz"
  sha256 "65d211bb59d71cfb1ddc36dce84f2dfa6481bb0ac5a468f5505f8617a3d0a31d"
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
