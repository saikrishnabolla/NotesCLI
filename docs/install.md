# Install Notes CLI

Notes CLI requires macOS 14 or later.

## Homebrew

```bash
brew install saikrishnabolla/notescli/notescli
notescli onboard
```

The formula lives in the [saikrishnabolla/homebrew-notescli](https://github.com/saikrishnabolla/homebrew-notescli) tap. It installs the notarized universal release binary and does not build Swift source.

After `brew upgrade notescli`, run `notescli onboard` to update Notes CLI.app and resume the readiness checks.

## Release archive

Download the `.tar.gz` file and its `.sha256` file from the same release. Check the archive, then install it on your `PATH`:

```bash
grep 'tar.gz$' notescli-1.1.12-macos-universal.sha256 | shasum -a 256 -c -
tar -xzf notescli-1.1.12-macos-universal.tar.gz
mkdir -p "$HOME/.local/bin" "$HOME/Applications"
install -m 755 notescli "$HOME/.local/bin/notescli"
ditto "Notes CLI.app" "$HOME/Applications/Notes CLI.app"
"$HOME/.local/bin/notescli" onboard
```

## Source build

Install Xcode Command Line Tools, then run:

```bash
xcode-select --install
git clone https://github.com/saikrishnabolla/NotesCLI.git
cd NotesCLI
swift build -c release
install -m 755 .build/release/notescli "$HOME/.local/bin/notescli"
notescli doctor
```

A local source build is not notarized and does not include Notes CLI.app. It runs in the calling terminal, which needs its own permissions. Release archives include the signed and notarized app.

## Finish setup

```bash
notescli onboard
```

Onboarding starts `~/Applications/Notes CLI.app` in the background. If access is missing, it opens Full Disk Access in System Settings. Allow **Notes CLI**, then rerun `notescli onboard`.

Grant Automation, Camera, or Speech Recognition when a feature asks for it. Onboarding does not configure AI tools or remote access.

Check access:

```bash
notescli doctor
```

## After a macOS update

Run `notescli doctor --native --json`. Notes CLI checks its declared private-framework, Core Data, and SQLite contracts against the current system. If a declared contract changed, writes that require it stop before opening the Notes store. Other native features can still work. Plain-text writes may use AppleScript; rich writes fail instead of losing formatting.

For a live write/read/delete check, run `notescli doctor --native --canary --json`. The canary uses the `NotesCLI Test hardening` folder, verifies each test element through SQLite, then deletes the test note.

Full Disk Access has no programmatic grant. Setup can open the correct pane, but you must turn access on. Before that, Notes CLI can still list, search, and read plain note text through Notes Automation. JSON and MCP results label this path as `limited` and list the unavailable fields.
