# Install NotesCLI

NotesCLI requires macOS 14 or later.

## Homebrew

```bash
brew install saikrishnabolla/notescli/notescli
notescli setup
```

The formula lives in the [saikrishnabolla/homebrew-notescli](https://github.com/saikrishnabolla/homebrew-notescli) tap. It installs the notarized universal release binary and does not build Swift source.

## Release archive

Download the `.tar.gz` file and its `.sha256` file from the same release. Check the archive, then install it on your `PATH`:

```bash
grep 'tar.gz$' notescli-1.0.3-macos-universal.sha256 | shasum -a 256 -c -
tar -xzf notescli-1.0.3-macos-universal.tar.gz
install -m 755 notescli "$HOME/.local/bin/notescli"
notescli setup
```

## Source build

Install Xcode Command Line Tools, then run:

```bash
xcode-select --install
git clone https://github.com/saikrishnabolla/NotesCLI.git
cd NotesCLI
swift build -c release
install -m 755 .build/release/notescli "$HOME/.local/bin/notescli"
notescli setup
```

A local source build is not notarized. Release archives are signed with Developer ID and notarized by Apple.

## Grant permissions

```bash
notescli permissions
```

The command opens **System Settings > Privacy & Security > Full Disk Access**. Add the app that starts NotesCLI:

- Add Terminal, iTerm, or another terminal for shell commands.
- Add Claude, Codex, Cursor, or VS Code when that app starts the MCP server.

The command also asks Notes for its app name. This reads no note content and triggers the Automation consent prompt. Allow the same terminal or MCP host app to control Notes.

Check access:

```bash
notescli doctor
```

Full Disk Access has no programmatic grant. Setup can open the correct pane, but you must turn access on.
