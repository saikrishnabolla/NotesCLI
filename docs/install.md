# Install NotesCLI

NotesCLI requires macOS 14 or later.

## Homebrew

```bash
brew install saikrishnabolla/notescli/notescli
notescli setup
```

The formula lives in the [saikrishnabolla/homebrew-notescli](https://github.com/saikrishnabolla/homebrew-notescli) tap. It installs the notarized universal release binary and does not build Swift source.

After `brew upgrade notescli`, run `notescli onboard` to replace the capability host with the same version.

## Release archive

Download the `.tar.gz` file and its `.sha256` file from the same release. Check the archive, then install it on your `PATH`:

```bash
grep 'tar.gz$' notescli-1.1.11-macos-universal.sha256 | shasum -a 256 -c -
tar -xzf notescli-1.1.11-macos-universal.tar.gz
install -m 755 notescli "$HOME/.local/bin/notescli"
mkdir -p "$HOME/Applications"
ditto "NotesCLI Capability Host.app" "$HOME/Applications/NotesCLI Capability Host.app"
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
notescli doctor
```

A local source build is not notarized and does not include the capability-host app. It runs in the calling terminal, which needs its own permissions. Release archives include the signed and notarized host.

## Grant permissions

```bash
notescli onboard
notescli permissions
```

Onboarding installs `~/Applications/NotesCLI Capability Host.app`. Add that app under **System Settings > Privacy & Security > Full Disk Access**. The CLI and MCP clients use its private socket, so each client does not need a separate grant.

The command also asks Notes for its app name. This reads no note content and triggers the Automation consent prompt. Allow NotesCLI Capability Host to control Notes.

Check access:

```bash
notescli doctor
```

## After a macOS update

Run `notescli doctor --native --json`. NotesCLI checks its declared private-framework, Core Data, and SQLite contracts against the current system. If a declared contract changed, writes that require it stop before opening the Notes store. Other native features can still work. Plain-text writes may use AppleScript; rich writes fail instead of losing formatting.

For a live write/read/delete check, run `notescli doctor --native --canary --json`. The canary uses the `NotesCLI Test hardening` folder, verifies each test element through SQLite, then deletes the test note.

Full Disk Access has no programmatic grant. Setup can open the correct pane, but you must turn access on. Before that, NotesCLI can still list, search, and read plain note text through Notes Automation. JSON and MCP results label this path as `limited` and list the unavailable fields.
