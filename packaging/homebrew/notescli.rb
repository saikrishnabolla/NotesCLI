class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.13/notescli-1.1.13-macos-universal.tar.gz"
  sha256 "80800f4523beca5161bae7861b77455b24dba3be36f05d177085614ca6f6d113"
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
