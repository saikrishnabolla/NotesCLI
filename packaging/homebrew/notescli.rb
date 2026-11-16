class Notescli < Formula
  desc "CLI and MCP server for Apple Notes"
  homepage "https://github.com/saikrishnabolla/NotesCLI"
  url "https://github.com/saikrishnabolla/NotesCLI/releases/download/v1.1.11/notescli-1.1.11-macos-universal.tar.gz"
  sha256 "8694639673b9d4532c0e5d052b01358f582fff626fcfc422027053d56615c146"
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
