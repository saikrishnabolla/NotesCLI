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
grep 'tar.gz$' notescli-1.1.11-macos-universal.sha256 | shasum -a 256 -c -
tar -xzf notescli-1.1.11-macos-universal.tar.gz
install -m 755 notescli "$HOME/.local/bin/notescli"
mkdir -p "$HOME/Applications"
ditto "Notes CLI.app" "$HOME/Applications/Notes CLI.app"
notescli onboard
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

Onboarding installs and starts `~/Applications/Notes CLI.app`. Add **Notes CLI** under **System Settings > Privacy & Security > Full Disk Access**, then return to the command. It saves progress, so rerunning `notescli onboard` continues at the unfinished step.

The command also triggers the Automation prompt without reading note content. Allow **Notes CLI** to control Notes. Grant Camera or Speech Recognition when you first use those features. `notescli setup` runs the same flow; `notescli permissions` reopens its permission step.

Check access:

```bash
notescli doctor
```

## After a macOS update

Run `notescli doctor --native --json`. Notes CLI checks its declared private-framework, Core Data, and SQLite contracts against the current system. If a declared contract changed, writes that require it stop before opening the Notes store. Other native features can still work. Plain-text writes may use AppleScript; rich writes fail instead of losing formatting.

For a live write/read/delete check, run `notescli doctor --native --canary --json`. The canary uses the `NotesCLI Test hardening` folder, verifies each test element through SQLite, then deletes the test note.

Full Disk Access has no programmatic grant. Setup can open the correct pane, but you must turn access on. Before that, Notes CLI can still list, search, and read plain note text through Notes Automation. JSON and MCP results label this path as `limited` and list the unavailable fields.
